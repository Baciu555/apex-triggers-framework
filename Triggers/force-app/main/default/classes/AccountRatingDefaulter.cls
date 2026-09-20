/**
 * Stand-in for a feature owned by "Package B": defaults Account.Rating to
 * 'Warm' on insert when left blank. Registered against Account BEFORE_INSERT
 * via a TriggerActionBinding__mdt record, at Order__c 20 - it runs after
 * AccountNameNormalizer because that order is declared in metadata, not
 * because of which class happened to deploy first.
 */
public class AccountRatingDefaulter implements TriggerAction.BeforeInsert {
    public void beforeInsert(List<SObject> newList) {
        for (Account acc : (List<Account>) newList) {
            if (acc.Rating == null) {
                acc.Rating = 'Warm';
            }
        }
    }
}
