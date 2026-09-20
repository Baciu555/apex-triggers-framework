/**
 * Direct unit tests for the sample Account handlers, calling them without the
 * dispatcher or a trigger in the way.
 *
 * These exist because the equivalent end-to-end assertions cannot actually
 * prove the handler ran. Salesforce trims leading and trailing whitespace on
 * text fields itself during a save, so an integration test that inserts
 * '  Acme Corp  ' and asserts the stored Name is 'Acme Corp' passes identically
 * whether AccountNameNormalizer is registered, unregistered, or deleted. The
 * only way to test the trimming is to call it directly and watch it mutate the
 * record in memory.
 */
@IsTest
private class AccountTriggerActionsTest {
    @IsTest
    static void testNameNormalizerTrimsSurroundingWhitespaceOnInsert() {
        List<Account> accounts = new List<Account>{
            new Account(Name = '  Leading'),
            new Account(Name = 'Trailing  '),
            new Account(Name = '  Both  '),
            new Account(Name = 'Clean')
        };

        new AccountNameNormalizer().beforeInsert(accounts);

        System.assertEquals('Leading', accounts[0].Name);
        System.assertEquals('Trailing', accounts[1].Name);
        System.assertEquals('Both', accounts[2].Name);
        System.assertEquals('Clean', accounts[3].Name, 'A name with no surrounding whitespace should be left alone');
    }

    @IsTest
    static void testNameNormalizerLeavesInnerWhitespaceAlone() {
        List<Account> accounts = new List<Account>{ new Account(Name = '  Acme  Holdings  Ltd  ') };

        new AccountNameNormalizer().beforeInsert(accounts);

        System.assertEquals('Acme  Holdings  Ltd', accounts[0].Name, 'Only the ends are trimmed; inner spacing is the customer\'s data');
    }

    @IsTest
    static void testNameNormalizerIgnoresBlankNames() {
        List<Account> accounts = new List<Account>{ new Account(Name = null), new Account(Name = '   ') };

        new AccountNameNormalizer().beforeInsert(accounts);

        System.assertEquals(null, accounts[0].Name, 'A null name should be left for the platform to reject');
        System.assertEquals('   ', accounts[1].Name, 'A whitespace-only name is blank, so it is skipped rather than emptied');
    }

    @IsTest
    static void testNameNormalizerTrimsOnUpdateToo() {
        List<Account> accounts = new List<Account>{ new Account(Name = '  Renamed  ') };

        new AccountNameNormalizer().beforeUpdate(accounts, new Map<Id, SObject>());

        System.assertEquals('Renamed', accounts[0].Name);
    }

    @IsTest
    static void testRatingDefaulterOnlyFillsABlankRating() {
        List<Account> accounts = new List<Account>{
            new Account(Name = 'No Rating', Rating = null),
            new Account(Name = 'Already Hot', Rating = 'Hot')
        };

        new AccountRatingDefaulter().beforeInsert(accounts);

        System.assertEquals('Warm', accounts[0].Rating, 'A blank Rating should default to Warm');
        System.assertEquals('Hot', accounts[1].Rating, 'An explicit Rating must not be overwritten');
    }
}
