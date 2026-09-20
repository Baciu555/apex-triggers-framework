/**
 * Stand-in for a feature owned by "Package A": trims Account.Name before it
 * saves. Registered against Account BEFORE_INSERT and BEFORE_UPDATE via
 * TriggerActionBinding__mdt records, at Order__c 10 - it never references
 * AccountRatingDefaulter, or knows it exists, even though both act on the
 * same object and the same trigger context.
 */
public class AccountNameNormalizer implements TriggerAction.BeforeInsert, TriggerAction.BeforeUpdate {
    public void beforeInsert(List<SObject> newList) {
        this.trimNames((List<Account>) newList);
    }
// this should be deleted XDDD
    public void XD() {
    for (int i = 0; i < 100; i++) {
        System.debug(i);
}
}

    public void beforeUpdate(List<SObject> newList, Map<Id, SObject> oldMap) {
        this.trimNames((List<Account>) newList);
    }

    private void trimNames(List<Account> accounts) {
        for (Account acc : accounts) {
            if (String.isNotBlank(acc.Name)) {
                acc.Name = acc.Name.trim();
            }
        }
    }
}
