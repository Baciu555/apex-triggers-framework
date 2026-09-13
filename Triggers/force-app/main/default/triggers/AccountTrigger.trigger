/**
 * The only trigger on Account. Every package that needs to act on Account
 * registers a TriggerActionBinding__mdt record instead of adding a second
 * trigger here - see TriggerActionDispatcher for why.
 */
trigger AccountTrigger on Account (
    before insert,
    before update,
    before delete,
    after insert,
    after update,
    after delete,
    after undelete
) {
    TriggerActionDispatcher.run(Account.SObjectType);
}
