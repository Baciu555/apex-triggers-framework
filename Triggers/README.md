# Trigger framework

One trigger per object. Everything that trigger should do is registered in
custom metadata, not in Apex.

The point is execution order. When two features — or two managed packages —
both need to act on Account, the usual outcome is two triggers and no defined
order between them. Here there is exactly one trigger per object, it does
nothing but call `TriggerActionDispatcher`, and each feature contributes a
`TriggerActionBinding__mdt` record saying which class runs, in which trigger
context, at which position. Order becomes a setting an admin can read and
change, rather than a property of which package happened to deploy last.

```apex
trigger AccountTrigger on Account (before insert, before update, /* ... */) {
    TriggerActionDispatcher.run(Account.SObjectType);
}
```

## Adding a handler

1. Write a class implementing the `TriggerAction` interface for each context it
   needs. It must be `public` (or `global`) with a public no-argument
   constructor.

   ```apex
   public class AccountRatingDefaulter implements TriggerAction.BeforeInsert {
       public void beforeInsert(List<SObject> newList) {
           for (Account acc : (List<Account>) newList) {
               if (acc.Rating == null) {
                   acc.Rating = 'Warm';
               }
           }
       }
   }
   ```

2. Add a `TriggerActionBinding__mdt` record — one per context the class handles.
   A class registered for a context it does not implement fails loudly on the
   first save; it does not quietly skip.

3. If the object has no trigger yet, add one. It should contain only the
   `TriggerActionDispatcher.run(...)` call.

`TriggerActionBindingHealthCheckTest` walks every deployed binding and fails the
build if any of them names a class that doesn't exist, can't be instantiated,
doesn't implement the interface its context requires, or points at an SObject
API name the platform doesn't describe under that spelling. Registry-driven
wiring is invisible to the compiler, so this test is what replaces the
compile-time check you'd otherwise have.

### Ordering

`Order__c` is ascending within one object and context. Leave gaps — 10, 20, 30 —
so a later feature can insert between two existing handlers without renumbering.
Bindings that share an `Order__c` fall back to `DeveloperName`, which is
arbitrary but at least reproducible; if the sequence matters, say so with
distinct orders rather than relying on the tie-break.

### Reading the current context

The interfaces deliberately take only record collections. A handler that needs
more — usually because one class is registered against several objects or
several contexts — reads it from the dispatcher:

```apex
TriggerAction.Context ctx = TriggerActionDispatcher.getContext();
// ctx.sObjectApiName, ctx.triggerContext, ctx.operationType,
// ctx.size, ctx.actionClassName, ctx.bindingDeveloperName
```

## Turning handlers off

Three mechanisms, from most permanent to least:

| | Scope | Takes effect | Use for |
|---|---|---|---|
| `Is_Disabled__c` on the binding | That binding, everyone | Needs a deployment | Retiring a handler |
| `Bypass_Permission__c` + a Custom Permission | That binding, users holding the permission | Permission set assignment | Integration users, data loads |
| `TriggerActionDispatcher.bypass('ClassName')` | That class, current transaction | Immediately | A handler that must not re-enter during its own DML |

The `Bypass_Trigger_Actions` custom permission is the org-wide version: a user
holding it skips **every** registered handler on every object. The
`Trigger_Action_Bypass` permission set grants it. Assign it narrowly — it turns
off other packages' logic too, including handlers acting as validation.

## When a handler fails

By default an exception from a handler aborts the save, which is what you want
when the handler is enforcing something. Tick `Allow_Failure__c` on a binding
and the exception is logged and swallowed instead, later handlers still run, and
the save completes. Retrieve what was swallowed in the same transaction:

```apex
for (TriggerActionDispatcher.ActionFailure f : TriggerActionDispatcher.getFailures()) {
    System.debug(f.describe());
}
```

Two things to know before ticking it:

- It also swallows *registration* errors — a misspelled class name on that
  binding becomes a silent no-op rather than a loud failure. The health check
  test is your cover for that.
- It does not swallow a runaway-recursion abort. That is a framework-level stop
  and always aborts the transaction.

Failures are held in memory for the transaction only. If you need them durably,
publish a Platform Event from a wrapper around `getFailures()` — that was
deliberately left out of the framework, because event volume, delivery
semantics, and who consumes them are org-level decisions rather than something
a trigger framework should choose for you.

## Recursion

The dispatcher caps how deep a single action class may **re-enter itself**, at 5
levels. This counts nesting depth, not total invocations: a transaction that
saves Accounts in ten separate DML statements is ordinary work and is not
capped. What trips it is a handler that re-saves the record it is handling
without a guard.

`TriggerActionDispatcher.setMaxDepth(n)` raises the cap; a negative number
removes it.

## Namespaces

- `Apex_Class_Name__c` for a class in another package needs its namespace:
  `pkgA.AccountNameNormalizer`. Inner classes work too — `pkgA.Outer.Inner`.
- `SObject_API_Name__c` must match what `getDescribe().getName()` returns, which
  for a custom object inside a namespaced package includes the prefix
  (`WB__Invoice__c`, not `Invoice__c`). A mismatch means the binding silently
  never matches, which is why the health check test asserts the two agree.
- `Bypass_Permission__c` likewise needs the namespace for a permission owned by
  another package.

## Deploying

Deploy the code and the custom metadata **type** first, and the binding
**records** second. A type and its records cannot be created in one deploy —
the records validate against a type that does not exist yet.

```sh
# 1. the type, the fields, the Apex, the permissions
sf project deploy start \
  --source-dir force-app/main/default/objects \
  --source-dir force-app/main/default/classes \
  --source-dir force-app/main/default/triggers \
  --source-dir force-app/main/default/customPermissions \
  --source-dir force-app/main/default/permissionsets

# 2. the binding records
sf project deploy start --source-dir force-app/main/default/customMetadata
```

### If step 2 fails with UNKNOWN_EXCEPTION

Some orgs reject the record deploy with

```
UNKNOWN_EXCEPTION: An unexpected error occurred. Please include this ErrorId ...
```

and **zero component errors**, which gives you nothing to work from. It is not
the record contents: this reproduces with a single minimal record containing
only the required fields, with and without a `fullName` attribute, at API
versions 62.0 and 67.0, with and without a namespace in `sfdx-project.json`,
and after the type is confirmed present and correctly described in the org.

Use the Apex Metadata API instead, which is a different code path and works:

```sh
sf apex run --file scripts/apex/deployTriggerActionBindings.apex
```

That deployment is asynchronous — the records appear a few seconds later.
Confirm with:

```sh
sf data query --query "SELECT DeveloperName, Apex_Class_Name__c, Trigger_Context__c, Order__c FROM TriggerActionBinding__mdt ORDER BY DeveloperName"
```

`force-app/main/default/customMetadata/` remains the source of truth; the script
is only a way to get it into an org, so keep the two in sync.

Once the type and records exist, ordinary full-directory deploys work for
everything else.

## Two frameworks live here

`TriggerActionDispatcher` is canonical and is what `AccountTrigger` uses.

`TriggerHandler` is the older one-handler-per-object base class: the trigger
constructs a subclass and calls `run()`. It is still here and still tested, and
it is reasonable for an object that one team owns outright and that only needs a
lifecycle base class. Prefer the dispatcher for anything where more than one
feature touches the object.

They do not interoperate. `TriggerHandler.bypass()` does not suppress a
dispatcher action, they read different metadata types
(`TriggerHandlerSetting__mdt` vs `TriggerActionBinding__mdt`), and they keep
separate recursion state. Don't register the same logic in both.

## Security note

Bindings name an Apex class that the dispatcher instantiates via
`Type.forName()`. Anyone who can deploy custom metadata can therefore cause
arbitrary Apex to run in trigger context. That is inherent to a registry-driven
design and is acceptable because deploying metadata is already privileged — but
it is a deliberate trade, and worth knowing before you grant someone the ability
to edit these records in production.
