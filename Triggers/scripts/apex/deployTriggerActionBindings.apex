/**
 * Creates the TriggerActionBinding__mdt records through the Apex Metadata API.
 *
 * Fallback for orgs where the ordinary file-based deploy of
 * force-app/main/default/customMetadata/ fails. Some orgs reject that deploy
 * with a bare `UNKNOWN_EXCEPTION` and zero component errors, at any API
 * version and even for a single minimal record - see the Deploying section of
 * the README. This path uses a different API and works where that one doesn't.
 *
 *   sf apex run --file scripts/apex/deployTriggerActionBindings.apex
 *
 * The deployment is asynchronous: the records appear a few seconds after the
 * script reports success. Confirm with
 *
 *   sf data query --query "SELECT DeveloperName, Apex_Class_Name__c, Trigger_Context__c, Order__c FROM TriggerActionBinding__mdt ORDER BY DeveloperName"
 *
 * Upserting by fullName, so it is safe to re-run. KEEP THE VALUES BELOW IN SYNC
 * with force-app/main/default/customMetadata/ - that directory stays the source
 * of truth, this is only a way to get it into an org.
 */

List<Map<String, Object>> rows = new List<Map<String, Object>>{
    new Map<String, Object>{
        'developerName' => 'Account_BeforeInsert_NameNormalizer',
        'label' => 'Account Before Insert - Name Normalizer',
        'SObject_API_Name__c' => 'Account',
        'Trigger_Context__c' => 'BEFORE_INSERT',
        'Apex_Class_Name__c' => 'AccountNameNormalizer',
        'Order__c' => 10,
        'Is_Disabled__c' => false,
        'Allow_Failure__c' => false,
        'Description__c' => 'Owned by "Package A" - trims Account.Name before save.'
    },
    new Map<String, Object>{
        'developerName' => 'Account_BeforeInsert_RatingDefaulter',
        'label' => 'Account Before Insert - Rating Defaulter',
        'SObject_API_Name__c' => 'Account',
        'Trigger_Context__c' => 'BEFORE_INSERT',
        'Apex_Class_Name__c' => 'AccountRatingDefaulter',
        'Order__c' => 20,
        'Is_Disabled__c' => false,
        'Allow_Failure__c' => false,
        'Description__c' => 'Owned by "Package B" - defaults Account.Rating to Warm when blank.'
    },
    new Map<String, Object>{
        'developerName' => 'Account_BeforeUpdate_NameNormalizer',
        'label' => 'Account Before Update - Name Normalizer',
        'SObject_API_Name__c' => 'Account',
        'Trigger_Context__c' => 'BEFORE_UPDATE',
        'Apex_Class_Name__c' => 'AccountNameNormalizer',
        'Order__c' => 10,
        'Is_Disabled__c' => false,
        'Allow_Failure__c' => false,
        'Description__c' => 'Owned by "Package A" - trims Account.Name before save.'
    }
};

List<String> fieldNames = new List<String>{
    'SObject_API_Name__c',
    'Trigger_Context__c',
    'Apex_Class_Name__c',
    'Order__c',
    'Is_Disabled__c',
    'Allow_Failure__c',
    'Description__c'
};

Metadata.DeployContainer container = new Metadata.DeployContainer();

for (Map<String, Object> row : rows) {
    Metadata.CustomMetadata record = new Metadata.CustomMetadata();
    record.fullName = 'TriggerActionBinding.' + (String) row.get('developerName');
    record.label = (String) row.get('label');

    for (String fieldName : fieldNames) {
        Metadata.CustomMetadataValue value = new Metadata.CustomMetadataValue();
        value.field = fieldName;
        value.value = row.get(fieldName);
        record.values.add(value);
    }

    container.addMetadata(record);
}

Id jobId = Metadata.Operations.enqueueDeployment(container, null);
System.debug(LoggingLevel.ERROR, 'Enqueued custom metadata deployment ' + jobId + ' for ' + rows.size() + ' binding(s).');
