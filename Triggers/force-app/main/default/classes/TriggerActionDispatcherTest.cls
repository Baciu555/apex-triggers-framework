/**
 * Declared public (not the usual private) so TriggerActionDispatcher can
 * resolve this class's nested fake actions via Type.forName() by their
 * dot-qualified name, e.g. TriggerActionDispatcherTest.FakeCountingAction.
 */
@IsTest
public class TriggerActionDispatcherTest {
    private static Integer invocationCount = 0;
    private static Integer largestBatchSeen = 0;
    private static List<String> executionLog = new List<String>();
    private static TriggerAction.Context capturedContext;

    // ---------------------------------------------------------------- guards

    @IsTest
    static void testRunOutsideTriggerContextThrows() {
        Boolean exceptionThrown = false;
        try {
            TriggerActionDispatcher.run(Account.SObjectType);
        } catch (TriggerActionDispatcher.TriggerActionDispatcherException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('outside of a trigger'), 'Unexpected message: ' + e.getMessage());
        }
        System.assertEquals(true, exceptionThrown, 'run() should throw when there is no trigger or test context');
    }

    // -------------------------------------------------------------- ordering

    @IsTest
    static void testHandlersRunInDeclaredOrderRegardlessOfBindingOrder() {
        TriggerActionDispatcher.testBindings = new List<TriggerActionBinding__mdt>{
            bindingFor('TriggerActionDispatcherTest.FakeOrderSecondAction', 20, 'BEFORE_INSERT'),
            bindingFor('TriggerActionDispatcherTest.FakeOrderFirstAction', 10, 'BEFORE_INSERT')
        };

        insert new Account(Name = 'Order Test');

        System.assertEquals(new List<String>{ 'first', 'second' }, executionLog, 'Lower Order__c should run first, independent of binding list order');
    }

    @IsTest
    static void testTiedOrdersBreakDeterministicallyByDeveloperName() {
        // Both at Order__c 10. Without a tie-break these would run in
        // whatever sequence the source list happened to be in, so the list is
        // deliberately seeded "wrong" - Second before First.
        TriggerActionBinding__mdt second = bindingFor('TriggerActionDispatcherTest.FakeOrderSecondAction', 10, 'BEFORE_INSERT');
        second.DeveloperName = 'B_Second';
        TriggerActionBinding__mdt first = bindingFor('TriggerActionDispatcherTest.FakeOrderFirstAction', 10, 'BEFORE_INSERT');
        first.DeveloperName = 'A_First';

        TriggerActionDispatcher.testBindings = new List<TriggerActionBinding__mdt>{ second, first };

        insert new Account(Name = 'Tie Break Test');

        System.assertEquals(
            new List<String>{ 'first', 'second' },
            executionLog,
            'Bindings sharing an Order__c should fall back to DeveloperName so the sequence is reproducible'
        );
    }

    @IsTest
    static void testNullOrderIsTreatedAsZeroAndRunsFirst() {
        TriggerActionBinding__mdt unordered = bindingFor('TriggerActionDispatcherTest.FakeOrderFirstAction', null, 'BEFORE_INSERT');
        TriggerActionDispatcher.testBindings = new List<TriggerActionBinding__mdt>{
            bindingFor('TriggerActionDispatcherTest.FakeOrderSecondAction', 20, 'BEFORE_INSERT'),
            unordered
        };

        insert new Account(Name = 'Null Order Test');

        System.assertEquals(new List<String>{ 'first', 'second' }, executionLog, 'A null Order__c should sort as 0, ahead of an explicit 20');
    }

    // ------------------------------------------------------ enable / disable

    @IsTest
    static void testDisabledBindingIsSkipped() {
        TriggerActionBinding__mdt disabled = bindingFor('TriggerActionDispatcherTest.FakeCountingAction', 10, 'BEFORE_INSERT');
        disabled.Is_Disabled__c = true;
        TriggerActionDispatcher.testBindings = new List<TriggerActionBinding__mdt>{ disabled };

        insert new Account(Name = 'Disabled Binding Test');

        System.assertEquals(0, invocationCount, 'A binding with Is_Disabled__c = true should not dispatch');
    }

    @IsTest
    static void testNullIsDisabledIsTreatedAsEnabled() {
        // getAll() never returns a null checkbox, but a hand-built binding
        // can - and dereferencing it used to throw from inside the framework.
        TriggerActionBinding__mdt nullFlag = bindingFor('TriggerActionDispatcherTest.FakeCountingAction', 10, 'BEFORE_INSERT');
        nullFlag.Is_Disabled__c = null;
        TriggerActionDispatcher.testBindings = new List<TriggerActionBinding__mdt>{ nullFlag };

        insert new Account(Name = 'Null Disabled Flag Test');

        System.assertEquals(1, invocationCount, 'A null Is_Disabled__c should dispatch normally rather than throw');
    }

    // -------------------------------------------------------------- bypasses

    @IsTest
    static void testBypassPreventsDispatchAndClearBypassRestoresIt() {
        String className = 'TriggerActionDispatcherTest.FakeCountingAction';
        TriggerActionDispatcher.testBindings = new List<TriggerActionBinding__mdt>{ bindingFor(className, 10, 'BEFORE_INSERT') };

        TriggerActionDispatcher.bypass(className);
        System.assertEquals(true, TriggerActionDispatcher.isBypassed(className), 'bypass() should be visible through isBypassed()');

        insert new Account(Name = 'Bypassed Test');
        System.assertEquals(0, invocationCount, 'Bypassed handler should not dispatch');

        TriggerActionDispatcher.clearBypass(className);
        System.assertEquals(false, TriggerActionDispatcher.isBypassed(className), 'clearBypass() should be visible through isBypassed()');

        insert new Account(Name = 'Not Bypassed Test');
        System.assertEquals(1, invocationCount, 'Handler should dispatch once bypass is cleared');
    }

    @IsTest
    static void testClearAllBypassesRestoresEveryHandler() {
        String className = 'TriggerActionDispatcherTest.FakeCountingAction';
        TriggerActionDispatcher.testBindings = new List<TriggerActionBinding__mdt>{ bindingFor(className, 10, 'BEFORE_INSERT') };

        TriggerActionDispatcher.bypass(className);
        TriggerActionDispatcher.bypass('SomeOtherClass');
        TriggerActionDispatcher.clearAllBypasses();

        System.assertEquals(false, TriggerActionDispatcher.isBypassed(className));
        System.assertEquals(false, TriggerActionDispatcher.isBypassed('SomeOtherClass'));

        insert new Account(Name = 'Clear All Bypasses Test');
        System.assertEquals(1, invocationCount, 'clearAllBypasses() should let every handler dispatch again');
    }

    @IsTest
    static void testBypassPermissionSuppressesOnlyItsOwnBinding() {
        TriggerActionBinding__mdt gated = bindingFor('TriggerActionDispatcherTest.FakeCountingAction', 10, 'BEFORE_INSERT');
        gated.Bypass_Permission__c = 'Skip_Counting_Action';

        TriggerActionDispatcher.testBindings = new List<TriggerActionBinding__mdt>{
            gated,
            bindingFor('TriggerActionDispatcherTest.FakeOrderFirstAction', 20, 'BEFORE_INSERT')
        };
        // Priming the cache stands in for the running user holding the
        // permission; assigning a real one mid-transaction isn't possible.
        TriggerActionDispatcher.customPermissionCache.put('Skip_Counting_Action', true);

        insert new Account(Name = 'Per Binding Permission Test');

        System.assertEquals(0, invocationCount, 'A binding whose Bypass_Permission__c the user holds should be skipped');
        System.assertEquals(new List<String>{ 'first' }, executionLog, 'Other bindings should be unaffected');
    }

    @IsTest
    static void testGlobalBypassPermissionSkipsEveryBinding() {
        TriggerActionDispatcher.testBindings = new List<TriggerActionBinding__mdt>{
            bindingFor('TriggerActionDispatcherTest.FakeCountingAction', 10, 'BEFORE_INSERT'),
            bindingFor('TriggerActionDispatcherTest.FakeOrderFirstAction', 20, 'BEFORE_INSERT')
        };
        TriggerActionDispatcher.customPermissionCache.put(TriggerActionDispatcher.GLOBAL_BYPASS_PERMISSION, true);

        insert new Account(Name = 'Global Bypass Test');

        System.assertEquals(0, invocationCount, 'The global bypass permission should skip every registered action');
        System.assertEquals(new List<String>(), executionLog, 'The global bypass permission should skip every registered action');
    }

    // ------------------------------------------------------ registration errors

    @IsTest
    static void testUnknownApexClassNameThrowsClearError() {
        TriggerActionDispatcher.testBindings = new List<TriggerActionBinding__mdt>{ bindingFor('NoSuchClassXyz123', 10, 'BEFORE_INSERT') };

        Boolean exceptionThrown = false;
        try {
            insert new Account(Name = 'Unknown Class Test');
        } catch (DmlException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('does not exist'), 'Unexpected message: ' + e.getMessage());
        }
        System.assertEquals(true, exceptionThrown, 'A binding pointing at a nonexistent class should fail loudly, not silently no-op');
    }

    @IsTest
    static void testClassWithoutNoArgConstructorThrowsClearError() {
        TriggerActionDispatcher.testBindings = new List<TriggerActionBinding__mdt>{
            bindingFor('TriggerActionDispatcherTest.FakeNoArgumentlessConstructorAction', 10, 'BEFORE_INSERT')
        };

        Boolean exceptionThrown = false;
        try {
            insert new Account(Name = 'No Default Constructor Test');
        } catch (DmlException e) {
            exceptionThrown = true;
            System.assert(
                e.getMessage().contains('no-argument constructor'),
                'The raw TypeException should be wrapped with the binding name and the likely cause. Got: ' + e.getMessage()
            );
        }
        System.assertEquals(true, exceptionThrown, 'A class that cannot be instantiated should fail with a clear message');
    }

    @IsTest
    static void testClassNotImplementingRequiredInterfaceThrowsClearError() {
        TriggerActionDispatcher.testBindings = new List<TriggerActionBinding__mdt>{
            bindingFor('TriggerActionDispatcherTest.FakeAfterInsertOnlyAction', 10, 'BEFORE_INSERT')
        };

        Boolean exceptionThrown = false;
        try {
            insert new Account(Name = 'Interface Mismatch Test');
        } catch (DmlException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('does not implement'), 'Unexpected message: ' + e.getMessage());
        }
        System.assertEquals(true, exceptionThrown, 'A class registered for a context it does not implement should fail with a clear message');
    }

    // ------------------------------------------------------- recursion guard

    @IsTest
    static void testUnrelatedDmlStatementsDoNotTripTheRecursionGuard() {
        // Regression test. The guard used to count total invocations per
        // transaction, so a routine batch of six separate saves - nothing
        // recursive about it - aborted at the sixth.
        TriggerActionDispatcher.testBindings = new List<TriggerActionBinding__mdt>{
            bindingFor('TriggerActionDispatcherTest.FakeCountingAction', 10, 'BEFORE_INSERT')
        };

        for (Integer i = 0; i < 10; i++) {
            insert new Account(Name = 'Sequential Insert ' + i);
        }

        System.assertEquals(10, invocationCount, 'Ten sequential, non-nested DML statements should all dispatch');
    }

    @IsTest
    static void testNestedReentryTripsTheDepthCap() {
        // This action re-saves the same object from inside its own before
        // insert, so each dispatch nests another one - the real runaway case.
        TriggerActionDispatcher.testBindings = new List<TriggerActionBinding__mdt>{
            bindingFor('TriggerActionDispatcherTest.FakeRecursingAction', 10, 'BEFORE_INSERT')
        };

        Boolean exceptionThrown = false;
        try {
            insert new Account(Name = 'Recursion Test');
        } catch (DmlException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('safety cap'), 'Unexpected message: ' + e.getMessage());
        }

        System.assertEquals(true, exceptionThrown, 'An action that re-enters itself should hit the depth cap');
        System.assert(invocationCount <= 5, 'The cap should stop nesting at 5 levels, saw ' + invocationCount);
    }

    // ----------------------------------------------------- context coverage

    @IsTest
    static void testEveryTriggerContextDispatchesExactlyOnce() {
        String className = 'TriggerActionDispatcherTest.FakeAllContextsAction';
        TriggerActionDispatcher.testBindings = new List<TriggerActionBinding__mdt>{
            bindingFor(className, 10, 'BEFORE_INSERT'),
            bindingFor(className, 10, 'AFTER_INSERT'),
            bindingFor(className, 10, 'BEFORE_UPDATE'),
            bindingFor(className, 10, 'AFTER_UPDATE'),
            bindingFor(className, 10, 'BEFORE_DELETE'),
            bindingFor(className, 10, 'AFTER_DELETE'),
            bindingFor(className, 10, 'AFTER_UNDELETE')
        };

        Account acc = new Account(Name = 'Lifecycle Test');
        insert acc;
        acc.Rating = 'Hot';
        update acc;
        delete acc;
        undelete acc;

        System.assertEquals(
            new List<String>{
                'BEFORE_INSERT',
                'AFTER_INSERT',
                'BEFORE_UPDATE',
                'AFTER_UPDATE',
                'BEFORE_DELETE',
                'AFTER_DELETE',
                'AFTER_UNDELETE'
            },
            executionLog,
            'Each of the seven contexts should dispatch once, in lifecycle order, with the right record collections'
        );
    }

    @IsTest
    static void testBulkSaveDispatchesOncePerStatementWithEveryRecord() {
        TriggerActionDispatcher.testBindings = new List<TriggerActionBinding__mdt>{
            bindingFor('TriggerActionDispatcherTest.FakeCountingAction', 10, 'BEFORE_INSERT')
        };

        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < 200; i++) {
            accounts.add(new Account(Name = 'Bulk Account ' + i));
        }

        insert accounts;

        System.assertEquals(1, invocationCount, 'A 200-record save should dispatch the handler once, not once per record');
        System.assertEquals(200, largestBatchSeen, 'The handler should receive all 200 records in a single call');
    }

    @IsTest
    static void testContextExposesObjectPhaseAndBinding() {
        TriggerActionBinding__mdt binding = bindingFor('TriggerActionDispatcherTest.FakeContextCapturingAction', 10, 'BEFORE_INSERT');
        binding.DeveloperName = 'Context_Probe';
        TriggerActionDispatcher.testBindings = new List<TriggerActionBinding__mdt>{ binding };

        insert new List<Account>{ new Account(Name = 'Context A'), new Account(Name = 'Context B') };

        System.assertNotEquals(null, capturedContext, 'A dispatched action should be able to read its context');
        System.assertEquals('Account', capturedContext.sObjectApiName);
        System.assertEquals('BEFORE_INSERT', capturedContext.triggerContext);
        System.assertEquals(System.TriggerOperation.BEFORE_INSERT, capturedContext.operationType);
        System.assertEquals(2, capturedContext.size);
        System.assertEquals('TriggerActionDispatcherTest.FakeContextCapturingAction', capturedContext.actionClassName);
        System.assertEquals('Context_Probe', capturedContext.bindingDeveloperName);
    }

    @IsTest
    static void testContextIsNullOutsideOfADispatchedAction() {
        System.assertEquals(null, TriggerActionDispatcher.getContext(), 'There is no action in flight outside of dispatch');
    }

    // --------------------------------------------------------- failure modes

    @IsTest
    static void testHandlerExceptionAbortsTheSaveByDefault() {
        TriggerActionDispatcher.testBindings = new List<TriggerActionBinding__mdt>{
            bindingFor('TriggerActionDispatcherTest.FakeThrowingAction', 10, 'BEFORE_INSERT')
        };

        Boolean exceptionThrown = false;
        try {
            insert new Account(Name = 'Throwing Handler Test');
        } catch (DmlException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('deliberate handler failure'), 'The handler message should survive. Got: ' + e.getMessage());
        }

        System.assertEquals(true, exceptionThrown, 'Without Allow_Failure__c a throwing handler must abort the save');
        System.assertEquals(0, [SELECT COUNT() FROM Account WHERE Name = 'Throwing Handler Test'], 'The record should not have been saved');
    }

    @IsTest
    static void testAllowFailureLetsTheSaveSucceedAndRecordsTheFailure() {
        TriggerActionBinding__mdt tolerant = bindingFor('TriggerActionDispatcherTest.FakeThrowingAction', 10, 'BEFORE_INSERT');
        tolerant.Allow_Failure__c = true;
        tolerant.DeveloperName = 'Tolerant_Binding';

        TriggerActionDispatcher.testBindings = new List<TriggerActionBinding__mdt>{
            tolerant,
            bindingFor('TriggerActionDispatcherTest.FakeOrderSecondAction', 20, 'BEFORE_INSERT')
        };

        insert new Account(Name = 'Allow Failure Test');

        System.assertEquals(1, [SELECT COUNT() FROM Account WHERE Name = 'Allow Failure Test'], 'Allow_Failure__c should let the save complete');
        System.assertEquals(new List<String>{ 'second' }, executionLog, 'Later bindings should still run after a tolerated failure');

        List<TriggerActionDispatcher.ActionFailure> failures = TriggerActionDispatcher.getFailures();
        System.assertEquals(1, failures.size(), 'The swallowed failure should be retrievable');
        System.assertEquals('Tolerant_Binding', failures[0].bindingDeveloperName);
        System.assertEquals('BEFORE_INSERT', failures[0].triggerContext);
        System.assert(failures[0].describe().contains('deliberate handler failure'), 'describe() should carry the original message');

        TriggerActionDispatcher.clearFailures();
        System.assertEquals(0, TriggerActionDispatcher.getFailures().size(), 'clearFailures() should empty the log');
    }

    @IsTest
    static void testAllowFailureDoesNotSwallowTheDepthCap() {
        TriggerActionBinding__mdt tolerant = bindingFor('TriggerActionDispatcherTest.FakeRecursingAction', 10, 'BEFORE_INSERT');
        tolerant.Allow_Failure__c = true;
        TriggerActionDispatcher.testBindings = new List<TriggerActionBinding__mdt>{ tolerant };

        Boolean exceptionThrown = false;
        try {
            insert new Account(Name = 'Tolerant Recursion Test');
        } catch (DmlException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('safety cap'), 'Unexpected message: ' + e.getMessage());
        }

        System.assertEquals(
            true,
            exceptionThrown,
            'Runaway recursion is a framework-level stop and must abort even a binding that tolerates failure'
        );
    }

    // --------------------------------------------------- deployed bindings

    // These two read the real TriggerActionBinding__mdt records rather than the
    // testBindings seam, so they only pass in an org those records are deployed
    // to - that is the point of them, but it does make them integration tests.
    //
    // Note the Name assertions below are weak on their own: the platform trims
    // whitespace on text fields during a save, so they would pass even with
    // AccountNameNormalizer unregistered. AccountTriggerActionsTest covers the
    // trimming behaviour properly by calling the handler directly; what these
    // add is proof that the bindings are wired to the right contexts.

    @IsTest
    static void testRealAccountBindingsNormalizeNameAndDefaultRatingOnInsert() {
        insert new Account(Name = '  Acme Corp  ');

        Account inserted = [SELECT Name, Rating FROM Account WHERE Name = 'Acme Corp' LIMIT 1];
        System.assertEquals('Acme Corp', inserted.Name, 'AccountNameNormalizer should trim the name');
        System.assertEquals('Warm', inserted.Rating, 'AccountRatingDefaulter should default a blank Rating to Warm');
    }

    @IsTest
    static void testRealAccountBindingsNormalizeNameOnUpdateWithoutTouchingRating() {
        Account acc = new Account(Name = 'Original Name', Rating = 'Hot');
        insert acc;

        acc.Name = '  Updated Name  ';
        update acc;

        Account updated = [SELECT Name, Rating FROM Account WHERE Id = :acc.Id];
        System.assertEquals('Updated Name', updated.Name, 'AccountNameNormalizer should trim the name on update too');
        System.assertEquals('Hot', updated.Rating, 'AccountRatingDefaulter is only registered for BEFORE_INSERT and should not run on update');
    }

    // ----------------------------------------------------------- test doubles

    private static TriggerActionBinding__mdt bindingFor(String className, Decimal order, String context) {
        return new TriggerActionBinding__mdt(
            DeveloperName = className.replace('.', '_') + '_' + context,
            SObject_API_Name__c = 'Account',
            Trigger_Context__c = context,
            Apex_Class_Name__c = className,
            Order__c = order,
            Is_Disabled__c = false,
            Allow_Failure__c = false
        );
    }

    public class FakeOrderFirstAction implements TriggerAction.BeforeInsert {
        public void beforeInsert(List<SObject> newList) {
            TriggerActionDispatcherTest.executionLog.add('first');
        }
    }

    public class FakeOrderSecondAction implements TriggerAction.BeforeInsert {
        public void beforeInsert(List<SObject> newList) {
            TriggerActionDispatcherTest.executionLog.add('second');
        }
    }

    public class FakeCountingAction implements TriggerAction.BeforeInsert {
        public void beforeInsert(List<SObject> newList) {
            TriggerActionDispatcherTest.invocationCount++;
            TriggerActionDispatcherTest.largestBatchSeen = Math.max(TriggerActionDispatcherTest.largestBatchSeen, newList.size());
        }
    }

    public class FakeAfterInsertOnlyAction implements TriggerAction.AfterInsert {
        public void afterInsert(List<SObject> newList, Map<Id, SObject> newMap) {
        }
    }

    public class FakeThrowingAction implements TriggerAction.BeforeInsert {
        public void beforeInsert(List<SObject> newList) {
            throw new FakeActionException('deliberate handler failure');
        }
    }

    public class FakeRecursingAction implements TriggerAction.BeforeInsert {
        public void beforeInsert(List<SObject> newList) {
            TriggerActionDispatcherTest.invocationCount++;
            insert new Account(Name = 'Nested ' + TriggerActionDispatcherTest.invocationCount);
        }
    }

    public class FakeContextCapturingAction implements TriggerAction.BeforeInsert {
        public void beforeInsert(List<SObject> newList) {
            TriggerActionDispatcherTest.capturedContext = TriggerActionDispatcher.getContext();
        }
    }

    /** Registered against all seven contexts, so one class exercises the whole matrix. */
    public class FakeAllContextsAction implements
        TriggerAction.BeforeInsert,
        TriggerAction.BeforeUpdate,
        TriggerAction.BeforeDelete,
        TriggerAction.AfterInsert,
        TriggerAction.AfterUpdate,
        TriggerAction.AfterDelete,
        TriggerAction.AfterUndelete
    {
        public void beforeInsert(List<SObject> newList) {
            log('BEFORE_INSERT', newList, null);
        }

        public void beforeUpdate(List<SObject> newList, Map<Id, SObject> oldMap) {
            log('BEFORE_UPDATE', newList, oldMap);
        }

        public void beforeDelete(List<SObject> oldList) {
            log('BEFORE_DELETE', oldList, null);
        }

        public void afterInsert(List<SObject> newList, Map<Id, SObject> newMap) {
            log('AFTER_INSERT', newList, newMap);
        }

        public void afterUpdate(List<SObject> newList, Map<Id, SObject> newMap, Map<Id, SObject> oldMap) {
            log('AFTER_UPDATE', newList, oldMap);
        }

        public void afterDelete(List<SObject> oldList, Map<Id, SObject> oldMap) {
            log('AFTER_DELETE', oldList, oldMap);
        }

        public void afterUndelete(List<SObject> newList) {
            log('AFTER_UNDELETE', newList, null);
        }

        /**
         * Asserting inside the double rather than only counting calls: the
         * casts in the dispatcher's switch are the thing most likely to be
         * wired to the wrong argument, and a bare call count would not notice.
         */
        private void log(String context, List<SObject> records, Map<Id, SObject> keyedRecords) {
            System.assertNotEquals(null, records, context + ' should receive a record collection');
            System.assertEquals(1, records.size(), context + ' should receive the one record being saved');

            if (keyedRecords != null) {
                System.assertEquals(records.size(), keyedRecords.size(), context + ' map and list should describe the same records');
            }

            TriggerActionDispatcherTest.executionLog.add(context);
        }
    }

    public class FakeNoArgumentlessConstructorAction implements TriggerAction.BeforeInsert {
        public FakeNoArgumentlessConstructorAction(String required) {
        }

        public void beforeInsert(List<SObject> newList) {
        }
    }

    public class FakeActionException extends Exception {
    }
}
