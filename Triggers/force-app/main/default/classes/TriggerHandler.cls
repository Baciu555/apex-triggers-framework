/**
 * Base class for all SObject trigger handlers.
 *
 * Usage: create one trigger per SObject that does nothing but dispatch,
 * e.g. `trigger AccountTrigger on Account (before insert, after insert) { new AccountTriggerHandler().run(); }`,
 * and one handler per SObject that extends this class and overrides the
 * lifecycle methods it needs.
 */
public virtual class TriggerHandler {
    private static Map<String, LoopCount> loopCountMap = new Map<String, LoopCount>();
    private static Set<String> bypassedHandlers = new Set<String>();

    private TriggerContext context;
    private Boolean isTriggerExecuting;
    private Boolean disabledByMetadata = false;

    public TriggerHandler() {
        this.setTriggerContext();
        this.applyHandlerSetting();
    }

    /**
     * Entry point called from the object's trigger. Dispatches to the
     * lifecycle method matching the current trigger context.
     */
    public void run() {
        if (!this.validateRun()) {
            return;
        }

        this.addToLoopCount();

        switch on this.context {
            when BEFORE_INSERT {
                this.beforeInsert();
            }
            when BEFORE_UPDATE {
                this.beforeUpdate();
            }
            when BEFORE_DELETE {
                this.beforeDelete();
            }
            when AFTER_INSERT {
                this.afterInsert();
            }
            when AFTER_UPDATE {
                this.afterUpdate();
            }
            when AFTER_DELETE {
                this.afterDelete();
            }
            when AFTER_UNDELETE {
                this.afterUndelete();
            }
        }
    }

    /**
     * Limits how many times this handler instance can re-enter run()
     * within the transaction. Pass a negative number for no limit.
     */
    public void setMaxLoopCount(Integer max) {
        String handlerName = this.getHandlerName();
        if (!TriggerHandler.loopCountMap.containsKey(handlerName)) {
            TriggerHandler.loopCountMap.put(handlerName, new LoopCount(max));
        } else {
            TriggerHandler.loopCountMap.get(handlerName).setMax(max);
        }
    }

    public void clearMaxLoopCount() {
        this.setMaxLoopCount(-1);
    }

    /** Suppresses the named handler's dispatch for the rest of the transaction. */
    public static void bypass(String handlerName) {
        TriggerHandler.bypassedHandlers.add(handlerName);
    }

    public static void clearBypass(String handlerName) {
        TriggerHandler.bypassedHandlers.remove(handlerName);
    }

    public static Boolean isBypassed(String handlerName) {
        return TriggerHandler.bypassedHandlers.contains(handlerName);
    }

    public static void clearAllBypasses() {
        TriggerHandler.bypassedHandlers.clear();
    }

    private void setTriggerContext() {
        if (!Trigger.isExecuting) {
            this.isTriggerExecuting = false;
            return;
        }

        this.isTriggerExecuting = true;

        if (Trigger.isBefore && Trigger.isInsert) {
            this.context = TriggerContext.BEFORE_INSERT;
        } else if (Trigger.isBefore && Trigger.isUpdate) {
            this.context = TriggerContext.BEFORE_UPDATE;
        } else if (Trigger.isBefore && Trigger.isDelete) {
            this.context = TriggerContext.BEFORE_DELETE;
        } else if (Trigger.isAfter && Trigger.isInsert) {
            this.context = TriggerContext.AFTER_INSERT;
        } else if (Trigger.isAfter && Trigger.isUpdate) {
            this.context = TriggerContext.AFTER_UPDATE;
        } else if (Trigger.isAfter && Trigger.isDelete) {
            this.context = TriggerContext.AFTER_DELETE;
        } else if (Trigger.isAfter && Trigger.isUndelete) {
            this.context = TriggerContext.AFTER_UNDELETE;
        }
    }

    /** Lets tests simulate a trigger context without a live trigger. */
    @TestVisible
    private void setTestContext(TriggerContext ctx) {
        this.isTriggerExecuting = true;
        this.context = ctx;
    }

    private Boolean validateRun() {
        if (!this.isTriggerExecuting || this.context == null) {
            throw new TriggerHandlerException('TriggerHandler.run() called outside of a trigger execution context');
        }
        if (this.disabledByMetadata) {
            return false;
        }
        if (TriggerHandler.bypassedHandlers.contains(this.getHandlerName())) {
            return false;
        }
        return true;
    }

    /**
     * Applies this handler's TriggerHandlerSetting__mdt record, if one exists
     * (matched by DeveloperName == this handler's class name). Is_Disabled__c
     * acts as an admin kill switch independent of the in-memory bypass() API;
     * Max_Loop_Count__c seeds the loop guard and can still be overridden by an
     * explicit setMaxLoopCount() call in the handler's own constructor.
     */
    private void applyHandlerSetting() {
        TriggerHandlerSetting__mdt setting = TriggerHandlerSetting__mdt.getInstance(this.getHandlerName());
        if (setting != null) {
            this.applyHandlerSetting(setting);
        }
    }

    private void applyHandlerSetting(TriggerHandlerSetting__mdt setting) {
        this.disabledByMetadata = setting.Is_Disabled__c;

        if (setting.Max_Loop_Count__c != null) {
            this.setMaxLoopCount(Integer.valueOf(setting.Max_Loop_Count__c));
        }
    }

    /** Custom metadata records can't be inserted via DML, so tests inject a setting directly. */
    @TestVisible
    private void setTestHandlerSetting(TriggerHandlerSetting__mdt setting) {
        this.applyHandlerSetting(setting);
    }

    private void addToLoopCount() {
        String handlerName = this.getHandlerName();
        if (TriggerHandler.loopCountMap.containsKey(handlerName)) {
            Boolean exceeded = TriggerHandler.loopCountMap.get(handlerName).increment();
            if (exceeded) {
                Integer max = TriggerHandler.loopCountMap.get(handlerName).getMax();
                throw new TriggerHandlerException(handlerName + ' has exceeded the maximum trigger loop count of ' + max);
            }
        }
    }

    @TestVisible
    private String getHandlerName() {
        // Default toString() is "ClassName:[field=value, ...]" - the class name
        // is used as the bypass key and as the TriggerHandlerSetting__mdt DeveloperName.
        String repr = String.valueOf(this);
        return repr.substring(0, repr.indexOf(':'));
    }

    protected virtual void beforeInsert() {
    }

    protected virtual void beforeUpdate() {
    }

    protected virtual void beforeDelete() {
    }

    protected virtual void afterInsert() {
    }

    protected virtual void afterUpdate() {
    }

    protected virtual void afterDelete() {
    }

    protected virtual void afterUndelete() {
    }

    private class LoopCount {
        private Integer max;
        private Integer count;

        private LoopCount(Integer max) {
            this.max = max;
            this.count = 0;
        }

        private Boolean increment() {
            this.count++;
            return this.exceeded();
        }

        private Boolean exceeded() {
            return this.max >= 0 && this.count > this.max;
        }

        private Integer getMax() {
            return this.max;
        }

        private void setMax(Integer max) {
            this.max = max;
        }
    }

    public enum TriggerContext {
        BEFORE_INSERT,
        BEFORE_UPDATE,
        BEFORE_DELETE,
        AFTER_INSERT,
        AFTER_UPDATE,
        AFTER_DELETE,
        AFTER_UNDELETE
    }

    public class TriggerHandlerException extends Exception {
    }
}
