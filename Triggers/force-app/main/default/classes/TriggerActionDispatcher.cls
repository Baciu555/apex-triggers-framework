/**
 * Single entry point for object triggers that need to run handler classes
 * contributed by more than one package.
 *
 * Usage: each object gets exactly one trigger, which does nothing but call
 * this dispatcher, e.g. `trigger AccountTrigger on Account (before insert,
 * before update, ...) { TriggerActionDispatcher.run(Account.SObjectType); }`.
 *
 * Every handler is registered declaratively via a TriggerActionBinding__mdt
 * record - SObject, trigger context, handler class name, and an explicit
 * Order__c - instead of owning its own trigger. That turns "which package's
 * logic runs first" from an accident of deploy order into a metadata setting
 * any package can contribute to without touching another package's code.
 * TriggerActionBinding__mdt.getAll() reads custom metadata from the platform
 * cache and does not count against the 100-query SOQL governor limit, so
 * dispatch itself is free no matter how many handlers are registered.
 *
 * Each handler class implements one or more TriggerAction interfaces for the
 * contexts it needs. A handler that throws, or that isn't registered for a
 * context it's called in, fails loudly with the offending class name rather
 * than silently no-oping - unless its binding opts into Allow_Failure__c.
 *
 * There are three ways to stop a handler running, in descending order of how
 * permanent they are:
 *   - Is_Disabled__c on the binding: an admin kill switch, but it takes a
 *     metadata deployment to flip.
 *   - Bypass_Permission__c on the binding, plus the org-wide
 *     `Bypass_Trigger_Actions` custom permission: assignable at runtime, so an
 *     integration user or a data load can skip handlers without a release.
 *   - bypass(className): in-memory, for the rest of the transaction only.
 *
 * SECURITY NOTE: bindings name an Apex class that this dispatcher instantiates
 * via Type.forName(). Anyone who can deploy custom metadata can therefore
 * cause arbitrary Apex to run in trigger context. That is inherent to a
 * registry-driven design and is acceptable because deploying metadata is
 * already a privileged operation - but it is a deliberate trade, not an
 * oversight.
 */
public inherited sharing class TriggerActionDispatcher {
    /**
     * How deep the same action class may re-enter dispatch before the
     * framework calls it runaway recursion. This counts nesting depth, not
     * total invocations: a transaction that saves the same object in six
     * separate, unrelated DML statements is normal and is not capped.
     */
    private static final Integer DEFAULT_MAX_DEPTH = 5;

    /** Custom permission that skips every registered action for the running user. */
    @TestVisible
    private static final String GLOBAL_BYPASS_PERMISSION = 'Bypass_Trigger_Actions';

    @TestVisible
    private static Integer maxDepth = DEFAULT_MAX_DEPTH;

    private static Map<String, Integer> activeDepthByClassName = new Map<String, Integer>();

    /**
     * Set once the depth cap trips. A runaway abort raised deep in a nest
     * crosses a DML boundary on its way out, which turns it into a DmlException
     * indistinguishable from ordinary handler failure - so without this flag an
     * outer Allow_Failure__c binding would swallow it and let the runaway save
     * proceed. Once set, every binding rethrows and the transaction aborts.
     */
    private static Boolean recursionAborted = false;
    private static Set<String> bypassedClassNames = new Set<String>();
    private static Map<String, List<TriggerActionBinding__mdt>> bindingsByObjectAndContext = new Map<String, List<TriggerActionBinding__mdt>>();
    private static List<ActionFailure> failures = new List<ActionFailure>();
    private static TriggerAction.Context currentContext;

    /**
     * Custom permission answers for this transaction. Also the test seam:
     * priming a name here stops checkPermission() being consulted for it,
     * which is the only way to exercise permission-gated paths without
     * creating and assigning real permission sets mid-test.
     */
    @TestVisible
    private static Map<String, Boolean> customPermissionCache = new Map<String, Boolean>();

    /** Test seam: when set, bindingsFor() reads this instead of TriggerActionBinding__mdt.getAll(). */
    @TestVisible
    private static List<TriggerActionBinding__mdt> testBindings;

    public static void run(SObjectType sObjectType) {
        if (!Trigger.isExecuting) {
            throw new TriggerActionDispatcherException('TriggerActionDispatcher.run() called outside of a trigger execution context');
        }

        if (hasCustomPermission(GLOBAL_BYPASS_PERMISSION)) {
            return;
        }

        String context = resolveContext();
        String objectName = sObjectType.getDescribe().getName();

        for (TriggerActionBinding__mdt binding : bindingsFor(objectName, context)) {
            // Suppression is re-evaluated per binding rather than baked into
            // the cached list, because bypass() can be called by a handler
            // that has already run earlier in this same loop.
            if (isSuppressed(binding)) {
                continue;
            }
            invoke(binding, context, objectName);
        }
    }

    /** Suppresses the named handler class's dispatch for the rest of the transaction. */
    public static void bypass(String className) {
        TriggerActionDispatcher.bypassedClassNames.add(className);
    }

    public static void clearBypass(String className) {
        TriggerActionDispatcher.bypassedClassNames.remove(className);
    }

    public static Boolean isBypassed(String className) {
        return TriggerActionDispatcher.bypassedClassNames.contains(className);
    }

    public static void clearAllBypasses() {
        TriggerActionDispatcher.bypassedClassNames.clear();
    }

    /**
     * What the dispatcher is doing right now, or null outside of a dispatched
     * action. See TriggerAction.Context for why this is a static lookup rather
     * than an interface parameter.
     */
    public static TriggerAction.Context getContext() {
        return TriggerActionDispatcher.currentContext;
    }

    /**
     * Handler failures swallowed because their binding set Allow_Failure__c.
     * Returned in the order they happened, and reset only by clearFailures()
     * or the end of the transaction.
     */
    public static List<ActionFailure> getFailures() {
        return TriggerActionDispatcher.failures;
    }

    public static void clearFailures() {
        TriggerActionDispatcher.failures.clear();
    }

    /** Raises the recursion depth cap. Pass a negative number to disable it. */
    public static void setMaxDepth(Integer depth) {
        TriggerActionDispatcher.maxDepth = depth;
    }

    /**
     * Instantiates the binding's class and checks it implements the interface
     * its context requires, throwing the same errors dispatch would. Lets a
     * test walk every deployed binding and turn a misregistration into a red
     * build rather than a production save failure - see
     * TriggerActionBindingHealthCheckTest.
     */
    public static void validateBinding(TriggerActionBinding__mdt binding) {
        assertImplementsContext(instantiate(binding), binding.Trigger_Context__c, binding);
    }

    private static String resolveContext() {
        if (Trigger.isBefore && Trigger.isInsert) {
            return 'BEFORE_INSERT';
        }
        if (Trigger.isBefore && Trigger.isUpdate) {
            return 'BEFORE_UPDATE';
        }
        if (Trigger.isBefore && Trigger.isDelete) {
            return 'BEFORE_DELETE';
        }
        if (Trigger.isAfter && Trigger.isInsert) {
            return 'AFTER_INSERT';
        }
        if (Trigger.isAfter && Trigger.isUpdate) {
            return 'AFTER_UPDATE';
        }
        if (Trigger.isAfter && Trigger.isDelete) {
            return 'AFTER_DELETE';
        }
        if (Trigger.isAfter && Trigger.isUndelete) {
            return 'AFTER_UNDELETE';
        }
        // Unreachable while Trigger.isExecuting, since every real phase is
        // covered above. Throwing rather than returning null keeps a future
        // platform phase from silently dispatching nothing.
        throw new TriggerActionDispatcherException(
            'Could not resolve a trigger context: isBefore=' + Trigger.isBefore + ', isAfter=' + Trigger.isAfter +
            ', operationType=' + Trigger.operationType
        );
    }

    private static Boolean isSuppressed(TriggerActionBinding__mdt binding) {
        if (TriggerActionDispatcher.bypassedClassNames.contains(binding.Apex_Class_Name__c)) {
            return true;
        }
        return String.isNotBlank(binding.Bypass_Permission__c) && hasCustomPermission(binding.Bypass_Permission__c);
    }

    private static Boolean hasCustomPermission(String permissionName) {
        if (!TriggerActionDispatcher.customPermissionCache.containsKey(permissionName)) {
            // Returns false rather than throwing for a permission that does
            // not exist, so an org that never created the bypass permission
            // simply never bypasses.
            TriggerActionDispatcher.customPermissionCache.put(permissionName, FeatureManagement.checkPermission(permissionName));
        }
        return TriggerActionDispatcher.customPermissionCache.get(permissionName);
    }

    private static List<TriggerActionBinding__mdt> bindingsFor(String objectName, String context) {
        if (TriggerActionDispatcher.testBindings != null) {
            return sortForDispatch(matchesIn(TriggerActionDispatcher.testBindings, objectName, context));
        }

        String cacheKey = objectName + '|' + context;
        if (!TriggerActionDispatcher.bindingsByObjectAndContext.containsKey(cacheKey)) {
            List<TriggerActionBinding__mdt> matches = matchesIn(TriggerActionBinding__mdt.getAll().values(), objectName, context);
            TriggerActionDispatcher.bindingsByObjectAndContext.put(cacheKey, sortForDispatch(matches));
        }
        return TriggerActionDispatcher.bindingsByObjectAndContext.get(cacheKey);
    }

    private static List<TriggerActionBinding__mdt> matchesIn(
        List<TriggerActionBinding__mdt> source,
        String objectName,
        String context
    ) {
        List<TriggerActionBinding__mdt> matches = new List<TriggerActionBinding__mdt>();
        for (TriggerActionBinding__mdt binding : source) {
            // `!= true` rather than `!`, because a hand-built binding from a
            // test can leave the checkbox null where getAll() never would.
            Boolean applies = binding.Is_Disabled__c != true &&
                binding.SObject_API_Name__c == objectName &&
                binding.Trigger_Context__c == context;
            if (applies) {
                matches.add(binding);
            }
        }
        return matches;
    }

    private static List<TriggerActionBinding__mdt> sortForDispatch(List<TriggerActionBinding__mdt> bindings) {
        // Insertion sort: registrations are typically a handful of records per
        // object/context, so simplicity wins over pulling in a Comparator.
        for (Integer i = 1; i < bindings.size(); i++) {
            TriggerActionBinding__mdt current = bindings[i];
            Integer j = i - 1;
            while (j >= 0 && compare(bindings[j], current) > 0) {
                bindings[j + 1] = bindings[j];
                j--;
            }
            bindings[j + 1] = current;
        }
        return bindings;
    }

    /**
     * Orders by Order__c, then by DeveloperName. The tie-break matters: the
     * source is getAll(), whose Map iteration order is not guaranteed, so
     * sorting on Order__c alone would leave two bindings that share an order
     * running in an arbitrary sequence - exactly the problem this framework
     * exists to remove.
     */
    private static Integer compare(TriggerActionBinding__mdt left, TriggerActionBinding__mdt right) {
        Decimal orderDifference = orderOf(left) - orderOf(right);
        if (orderDifference != 0) {
            return orderDifference < 0 ? -1 : 1;
        }
        return developerNameOf(left).compareTo(developerNameOf(right));
    }

    private static Decimal orderOf(TriggerActionBinding__mdt binding) {
        return binding.Order__c == null ? 0 : binding.Order__c;
    }

    private static String developerNameOf(TriggerActionBinding__mdt binding) {
        return binding.DeveloperName == null ? '' : binding.DeveloperName;
    }

    private static void invoke(TriggerActionBinding__mdt binding, String context, String objectName) {
        String className = binding.Apex_Class_Name__c;

        // Outside the try below on purpose: a runaway recursion abort is a
        // framework-level stop and must not be swallowed by Allow_Failure__c.
        enterAction(className);

        try {
            dispatch(binding, context, objectName);
        } catch (Exception e) {
            if (binding.Allow_Failure__c == true && !TriggerActionDispatcher.recursionAborted) {
                recordFailure(binding, context, e);
            } else {
                throw e;
            }
        } finally {
            exitAction(className);
        }
    }

    private static void dispatch(TriggerActionBinding__mdt binding, String context, String objectName) {
        Object action = instantiate(binding);
        assertImplementsContext(action, context, binding);

        TriggerAction.Context previousContext = TriggerActionDispatcher.currentContext;
        TriggerActionDispatcher.currentContext = new TriggerAction.Context(
            objectName,
            context,
            Trigger.operationType,
            Trigger.size,
            binding.Apex_Class_Name__c,
            binding.DeveloperName
        );

        try {
            switch on context {
                when 'BEFORE_INSERT' {
                    ((TriggerAction.BeforeInsert) action).beforeInsert(Trigger.new);
                }
                when 'BEFORE_UPDATE' {
                    ((TriggerAction.BeforeUpdate) action).beforeUpdate(Trigger.new, Trigger.oldMap);
                }
                when 'BEFORE_DELETE' {
                    ((TriggerAction.BeforeDelete) action).beforeDelete(Trigger.old);
                }
                when 'AFTER_INSERT' {
                    ((TriggerAction.AfterInsert) action).afterInsert(Trigger.new, Trigger.newMap);
                }
                when 'AFTER_UPDATE' {
                    ((TriggerAction.AfterUpdate) action).afterUpdate(Trigger.new, Trigger.newMap, Trigger.oldMap);
                }
                when 'AFTER_DELETE' {
                    ((TriggerAction.AfterDelete) action).afterDelete(Trigger.old, Trigger.oldMap);
                }
                when 'AFTER_UNDELETE' {
                    ((TriggerAction.AfterUndelete) action).afterUndelete(Trigger.new);
                }
            }
        } finally {
            // Restore rather than null out: a handler that performs its own
            // DML nests another dispatch inside this one.
            TriggerActionDispatcher.currentContext = previousContext;
        }
    }

    private static Object instantiate(TriggerActionBinding__mdt binding) {
        Type actionType = resolveType(binding.Apex_Class_Name__c);
        if (actionType == null) {
            throw new TriggerActionDispatcherException(
                'TriggerActionBinding__mdt "' + binding.DeveloperName + '" points at Apex class "' +
                binding.Apex_Class_Name__c + '", which does not exist or is not visible to this dispatcher'
            );
        }

        try {
            return actionType.newInstance();
        } catch (Exception e) {
            // Raw TypeException here names neither the binding nor the reason,
            // and "no public no-arg constructor" is the single most common way
            // a correctly-named registration still fails.
            throw new TriggerActionDispatcherException(
                'TriggerActionBinding__mdt "' + binding.DeveloperName + '" could not instantiate "' +
                binding.Apex_Class_Name__c + '". A handler must be public (or global) with a public no-argument ' +
                'constructor. Underlying error: ' + e.getMessage()
            );
        }
    }

    /**
     * Type.forName(String) resolves against the local namespace, so a class
     * contributed by another package as `pkgA.Outer.Inner` needs the two
     * argument overload. Trying the single-argument form first keeps local
     * inner classes like `MyTest.FakeAction` working unchanged.
     */
    private static Type resolveType(String className) {
        Type actionType = Type.forName(className);
        if (actionType != null || !className.contains('.')) {
            return actionType;
        }

        Integer firstDot = className.indexOf('.');
        return Type.forName(className.substring(0, firstDot), className.substring(firstDot + 1));
    }

    private static void assertImplementsContext(Object action, String context, TriggerActionBinding__mdt binding) {
        Boolean implementsIt;
        String interfaceName;

        switch on context {
            when 'BEFORE_INSERT' {
                implementsIt = action instanceof TriggerAction.BeforeInsert;
                interfaceName = 'TriggerAction.BeforeInsert';
            }
            when 'BEFORE_UPDATE' {
                implementsIt = action instanceof TriggerAction.BeforeUpdate;
                interfaceName = 'TriggerAction.BeforeUpdate';
            }
            when 'BEFORE_DELETE' {
                implementsIt = action instanceof TriggerAction.BeforeDelete;
                interfaceName = 'TriggerAction.BeforeDelete';
            }
            when 'AFTER_INSERT' {
                implementsIt = action instanceof TriggerAction.AfterInsert;
                interfaceName = 'TriggerAction.AfterInsert';
            }
            when 'AFTER_UPDATE' {
                implementsIt = action instanceof TriggerAction.AfterUpdate;
                interfaceName = 'TriggerAction.AfterUpdate';
            }
            when 'AFTER_DELETE' {
                implementsIt = action instanceof TriggerAction.AfterDelete;
                interfaceName = 'TriggerAction.AfterDelete';
            }
            when 'AFTER_UNDELETE' {
                implementsIt = action instanceof TriggerAction.AfterUndelete;
                interfaceName = 'TriggerAction.AfterUndelete';
            }
            when else {
                throw new TriggerActionDispatcherException(
                    'TriggerActionBinding__mdt "' + binding.DeveloperName + '" has an unrecognized trigger context: ' + context
                );
            }
        }

        if (!implementsIt) {
            throw new TriggerActionDispatcherException(
                binding.Apex_Class_Name__c + ' is registered for ' + binding.Trigger_Context__c +
                ' but does not implement ' + interfaceName
            );
        }
    }

    private static Integer depthOf(String className) {
        Integer depth = TriggerActionDispatcher.activeDepthByClassName.get(className);
        return depth == null ? 0 : depth;
    }

    private static void enterAction(String className) {
        Integer depth = depthOf(className);

        if (TriggerActionDispatcher.maxDepth >= 0 && depth >= TriggerActionDispatcher.maxDepth) {
            TriggerActionDispatcher.recursionAborted = true;
            throw new TriggerActionDispatcherException(
                className + ' is already ' + depth + ' levels deep in this transaction, at the safety cap of ' +
                TriggerActionDispatcher.maxDepth + '. This usually means the action re-saves its own record without a guard.'
            );
        }

        TriggerActionDispatcher.activeDepthByClassName.put(className, depth + 1);
    }

    private static void exitAction(String className) {
        TriggerActionDispatcher.activeDepthByClassName.put(className, depthOf(className) - 1);
    }

    private static void recordFailure(TriggerActionBinding__mdt binding, String context, Exception e) {
        ActionFailure failure = new ActionFailure(binding.DeveloperName, binding.Apex_Class_Name__c, context, e);
        TriggerActionDispatcher.failures.add(failure);
        System.debug(LoggingLevel.ERROR, failure.describe());
    }

    /** One handler failure that Allow_Failure__c kept from aborting the save. */
    public class ActionFailure {
        public final String bindingDeveloperName;
        public final String actionClassName;
        public final String triggerContext;
        public final Exception thrownException;

        private ActionFailure(String bindingDeveloperName, String actionClassName, String triggerContext, Exception thrownException) {
            this.bindingDeveloperName = bindingDeveloperName;
            this.actionClassName = actionClassName;
            this.triggerContext = triggerContext;
            this.thrownException = thrownException;
        }

        public String describe() {
            return 'TriggerActionDispatcher: ' + this.actionClassName + ' failed during ' + this.triggerContext +
                ' (binding "' + this.bindingDeveloperName + '") and was allowed to fail. ' +
                this.thrownException.getTypeName() + ': ' + this.thrownException.getMessage() +
                '\n' + this.thrownException.getStackTraceString();
        }
    }

    public class TriggerActionDispatcherException extends Exception {
    }
}
