/**
 * Namespace for the interfaces a TriggerActionDispatcher handler implements.
 *
 * A handler implements only the interfaces for the contexts it cares about,
 * e.g. `public class MyHandler implements TriggerAction.BeforeInsert { ... }`.
 * Which handlers run, for which object and context, and in what order, is
 * declared entirely in TriggerActionBinding__mdt records - not in this code.
 */
public inherited sharing class TriggerAction {
    public interface BeforeInsert {
        void beforeInsert(List<SObject> newList);
    }

    public interface BeforeUpdate {
        void beforeUpdate(List<SObject> newList, Map<Id, SObject> oldMap);
    }

    public interface BeforeDelete {
        void beforeDelete(List<SObject> oldList);
    }

    public interface AfterInsert {
        void afterInsert(List<SObject> newList, Map<Id, SObject> newMap);
    }

    public interface AfterUpdate {
        void afterUpdate(List<SObject> newList, Map<Id, SObject> newMap, Map<Id, SObject> oldMap);
    }

    public interface AfterDelete {
        void afterDelete(List<SObject> oldList, Map<Id, SObject> oldMap);
    }

    public interface AfterUndelete {
        void afterUndelete(List<SObject> newList);
    }

    /**
     * What the dispatcher knows about the invocation currently in flight.
     *
     * The interface methods above deliberately still take only the record
     * collections, so existing handlers keep compiling. A handler that needs
     * more - most often because one class is registered against several
     * objects or several contexts and has to tell them apart - reads it from
     * `TriggerActionDispatcher.getContext()` instead of from its parameters.
     */
    public class Context {
        /** API name of the object being saved, e.g. 'Account' or 'WB__Invoice__c'. */
        public final String sObjectApiName;

        /** Trigger phase, matching TriggerActionBinding__mdt.Trigger_Context__c, e.g. 'BEFORE_INSERT'. */
        public final String triggerContext;

        /** The platform's own view of the same phase, for handlers that prefer switching on an enum. */
        public final System.TriggerOperation operationType;

        /** Trigger.size - how many records are in this invocation. */
        public final Integer size;

        /** Apex_Class_Name__c of the binding that caused this handler to run. */
        public final String actionClassName;

        /** DeveloperName of that binding, so a handler can report which registration invoked it. */
        public final String bindingDeveloperName;

        public Context(
            String sObjectApiName,
            String triggerContext,
            System.TriggerOperation operationType,
            Integer size,
            String actionClassName,
            String bindingDeveloperName
        ) {
            this.sObjectApiName = sObjectApiName;
            this.triggerContext = triggerContext;
            this.operationType = operationType;
            this.size = size;
            this.actionClassName = actionClassName;
            this.bindingDeveloperName = bindingDeveloperName;
        }
    }
}
