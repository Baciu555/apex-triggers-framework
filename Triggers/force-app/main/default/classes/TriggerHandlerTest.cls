@IsTest
private class TriggerHandlerTest {
    @IsTest
    static void testConstructorOutsideTriggerLeavesNotExecuting() {
        TestHandler handler = new TestHandler();

        Boolean exceptionThrown = false;
        try {
            handler.run();
        } catch (TriggerHandler.TriggerHandlerException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('outside of a trigger'), 'Unexpected message: ' + e.getMessage());
        }

        System.assertEquals(true, exceptionThrown, 'run() should throw when there is no trigger or test context');
    }

    @IsTest
    static void testDispatchesToMatchingLifecycleMethod() {
        Map<TriggerHandler.TriggerContext, String> methodByContext = new Map<TriggerHandler.TriggerContext, String>{
            TriggerHandler.TriggerContext.BEFORE_INSERT => 'beforeInsert',
            TriggerHandler.TriggerContext.BEFORE_UPDATE => 'beforeUpdate',
            TriggerHandler.TriggerContext.BEFORE_DELETE => 'beforeDelete',
            TriggerHandler.TriggerContext.AFTER_INSERT => 'afterInsert',
            TriggerHandler.TriggerContext.AFTER_UPDATE => 'afterUpdate',
            TriggerHandler.TriggerContext.AFTER_DELETE => 'afterDelete',
            TriggerHandler.TriggerContext.AFTER_UNDELETE => 'afterUndelete'
        };

        for (TriggerHandler.TriggerContext ctx : methodByContext.keySet()) {
            TestHandler handler = new TestHandler();
            handler.setTestContext(ctx);

            handler.run();

            String expectedMethod = methodByContext.get(ctx);
            System.assertEquals(1, handler.callCounts.get(expectedMethod), expectedMethod + ' should have run exactly once for context ' + ctx);
        }
    }

    @IsTest
    static void testBypassPreventsDispatchAndClearBypassRestoresIt() {
        TestHandler handler = new TestHandler();
        handler.setTestContext(TriggerHandler.TriggerContext.BEFORE_INSERT);
        String handlerName = handler.getHandlerName();

        TriggerHandler.bypass(handlerName);
        System.assertEquals(true, TriggerHandler.isBypassed(handlerName));

        handler.run();
        System.assertEquals(0, handler.callCounts.get('beforeInsert'), 'Bypassed handler should not dispatch');

        TriggerHandler.clearBypass(handlerName);
        System.assertEquals(false, TriggerHandler.isBypassed(handlerName));

        handler.run();
        System.assertEquals(1, handler.callCounts.get('beforeInsert'), 'Handler should dispatch once bypass is cleared');
    }

    @IsTest
    static void testClearAllBypassesRemovesEveryBypass() {
        TestHandler handler = new TestHandler();
        String handlerName = handler.getHandlerName();

        TriggerHandler.bypass(handlerName);
        TriggerHandler.clearAllBypasses();

        System.assertEquals(false, TriggerHandler.isBypassed(handlerName));
    }

    @IsTest
    static void testMaxLoopCountExceededThrows() {
        TestHandler handler = new TestHandler();
        handler.setTestContext(TriggerHandler.TriggerContext.BEFORE_UPDATE);
        handler.setMaxLoopCount(2);

        handler.run();
        handler.run();

        Boolean exceptionThrown = false;
        try {
            handler.run();
        } catch (TriggerHandler.TriggerHandlerException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('maximum trigger loop count'), 'Unexpected message: ' + e.getMessage());
        }

        System.assertEquals(true, exceptionThrown, 'A third run() should exceed the configured max loop count of 2');
        System.assertEquals(2, handler.callCounts.get('beforeUpdate'));
    }

    @IsTest
    static void testSetMaxLoopCountUpdatesAnExistingLimit() {
        TestHandler handler = new TestHandler();
        handler.setTestContext(TriggerHandler.TriggerContext.BEFORE_UPDATE);
        handler.setMaxLoopCount(5);
        handler.setMaxLoopCount(1);

        handler.run();

        Boolean exceptionThrown = false;
        try {
            handler.run();
        } catch (TriggerHandler.TriggerHandlerException e) {
            exceptionThrown = true;
        }

        System.assertEquals(true, exceptionThrown, 'The narrower limit set on the second call should take effect');
    }

    @IsTest
    static void testClearMaxLoopCountRemovesTheLimit() {
        TestHandler handler = new TestHandler();
        handler.setTestContext(TriggerHandler.TriggerContext.BEFORE_UPDATE);
        handler.setMaxLoopCount(1);
        handler.clearMaxLoopCount();

        handler.run();
        handler.run();
        handler.run();

        System.assertEquals(3, handler.callCounts.get('beforeUpdate'), 'No exception should be thrown once the limit is cleared');
    }

    @IsTest
    static void testMetadataDisablesHandler() {
        TestHandler handler = new TestHandler();
        handler.setTestContext(TriggerHandler.TriggerContext.BEFORE_INSERT);
        handler.setTestHandlerSetting(new TriggerHandlerSetting__mdt(Is_Disabled__c = true));

        handler.run();

        System.assertEquals(0, handler.callCounts.get('beforeInsert'), 'A handler disabled via metadata should not dispatch');
    }

    @IsTest
    static void testNoMetadataRecordLeavesHandlerEnabled() {
        TestHandler handler = new TestHandler();
        handler.setTestContext(TriggerHandler.TriggerContext.BEFORE_INSERT);

        handler.run();

        System.assertEquals(1, handler.callCounts.get('beforeInsert'), 'With no matching metadata record, the handler should dispatch normally');
    }

    @IsTest
    static void testMetadataSetsMaxLoopCount() {
        TestHandler handler = new TestHandler();
        handler.setTestContext(TriggerHandler.TriggerContext.BEFORE_UPDATE);
        handler.setTestHandlerSetting(new TriggerHandlerSetting__mdt(Max_Loop_Count__c = 2));

        handler.run();
        handler.run();

        Boolean exceptionThrown = false;
        try {
            handler.run();
        } catch (TriggerHandler.TriggerHandlerException e) {
            exceptionThrown = true;
        }

        System.assertEquals(true, exceptionThrown, 'A third run() should exceed the metadata-configured max loop count of 2');
    }

    @IsTest
    static void testExplicitSetMaxLoopCountOverridesMetadata() {
        TestHandler handler = new TestHandler();
        handler.setTestContext(TriggerHandler.TriggerContext.BEFORE_UPDATE);
        handler.setTestHandlerSetting(new TriggerHandlerSetting__mdt(Max_Loop_Count__c = 1));
        handler.setMaxLoopCount(5);

        handler.run();
        handler.run();
        handler.run();

        System.assertEquals(3, handler.callCounts.get('beforeUpdate'), 'An explicit setMaxLoopCount() call after the metadata is applied should win');
    }

    private class TestHandler extends TriggerHandler {
        public Map<String, Integer> callCounts = new Map<String, Integer>{
            'beforeInsert' => 0,
            'beforeUpdate' => 0,
            'beforeDelete' => 0,
            'afterInsert' => 0,
            'afterUpdate' => 0,
            'afterDelete' => 0,
            'afterUndelete' => 0
        };

        protected override void beforeInsert() {
            this.increment('beforeInsert');
        }

        protected override void beforeUpdate() {
            this.increment('beforeUpdate');
        }

        protected override void beforeDelete() {
            this.increment('beforeDelete');
        }

        protected override void afterInsert() {
            this.increment('afterInsert');
        }

        protected override void afterUpdate() {
            this.increment('afterUpdate');
        }

        protected override void afterDelete() {
            this.increment('afterDelete');
        }

        protected override void afterUndelete() {
            this.increment('afterUndelete');
        }

        private void increment(String key) {
            this.callCounts.put(key, this.callCounts.get(key) + 1);
        }
    }
}
