/**
 * Walks every TriggerActionBinding__mdt record actually deployed to the org
 * and asserts it could dispatch.
 *
 * A registry-driven framework moves the wiring out of Apex, which means the
 * compiler no longer catches a typo in it: a misspelled class name, a handler
 * missing the interface for the context it was registered against, or an
 * object API name that doesn't exist, all deploy cleanly and then fail on the
 * first real save. This test is the replacement for that compile-time check -
 * it turns every one of those into a red build instead.
 *
 * It reads real metadata rather than the testBindings seam on purpose. That
 * means it is an integration test: it validates whatever the target org has,
 * so it also catches a binding an admin added by hand in production.
 */
@IsTest
private class TriggerActionBindingHealthCheckTest {
    @IsTest
    static void testEveryDeployedBindingResolvesToADispatchableHandler() {
        List<String> problems = new List<String>();

        for (TriggerActionBinding__mdt binding : TriggerActionBinding__mdt.getAll().values()) {
            try {
                TriggerActionDispatcher.validateBinding(binding);
            } catch (Exception e) {
                problems.add(binding.DeveloperName + ': ' + e.getMessage());
            }
        }

        // Reported together rather than failing on the first one, so a build
        // that broke several registrations at once shows all of them.
        System.assertEquals(
            new List<String>(),
            problems,
            'Every deployed TriggerActionBinding__mdt must name a class that exists, instantiates, and implements the ' +
            'interface for its Trigger_Context__c. Problems found: ' + String.join(problems, ' | ')
        );
    }

    @IsTest
    static void testEveryDeployedBindingNamesARealSObject() {
        List<String> problems = new List<String>();

        for (TriggerActionBinding__mdt binding : TriggerActionBinding__mdt.getAll().values()) {
            SObjectType sObjectType = Schema.getGlobalDescribe().get(binding.SObject_API_Name__c);
            if (sObjectType == null) {
                problems.add(binding.DeveloperName + ' points at unknown SObject "' + binding.SObject_API_Name__c + '"');
                continue;
            }

            // getAll() returns the API name an admin typed; the dispatcher
            // matches against describe output. In a namespaced package those
            // differ for custom objects unless the prefix is written in, and a
            // mismatch means the binding silently never dispatches.
            String describedName = sObjectType.getDescribe().getName();
            if (describedName != binding.SObject_API_Name__c) {
                problems.add(
                    binding.DeveloperName + ' records SObject_API_Name__c "' + binding.SObject_API_Name__c +
                    '" but the platform describes that object as "' + describedName +
                    '", so TriggerActionDispatcher will never match it'
                );
            }
        }

        System.assertEquals(
            new List<String>(),
            problems,
            'Problems found: ' + String.join(problems, ' | ')
        );
    }

    @IsTest
    static void testEveryDeployedBindingHasAnExplicitOrder() {
        List<String> missing = new List<String>();

        for (TriggerActionBinding__mdt binding : TriggerActionBinding__mdt.getAll().values()) {
            if (binding.Order__c == null) {
                missing.add(binding.DeveloperName);
            }
        }

        // Order__c is a required field, so this only catches a record that
        // predates that constraint - but an unordered binding silently sorts
        // to 0 and jumps ahead of everything, which is worth failing over.
        System.assertEquals(
            new List<String>(),
            missing,
            'Every binding needs an explicit Order__c. Missing on: ' + String.join(missing, ', ')
        );
    }
}
