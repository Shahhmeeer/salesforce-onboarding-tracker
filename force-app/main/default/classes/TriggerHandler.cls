/**
 * Base class for every trigger handler. A trigger only calls `new <Object>TriggerHandler().run();`
 * and the handler overrides the context methods it needs.
 *
 * run() checks two switches first: the Automation_Bypass__c kill switch (per user, profile or org,
 * set by an admin) and a code-level bypass that lasts for one transaction (set by tests or scripts).
 * Handlers are bypassed by their class name, worked out from the instance itself, so a subclass
 * needs no extra code to take part. Names are compared in lowercase because Apex class names are
 * case-insensitive.
 *
 * The name comes from String.valueOf(this) because Apex has no reflection to ask an instance for its
 * class name, and this makes the bypass key match the class without each handler repeating it.
 * Caveat: a handler that overrides toString() breaks this, so handlers must not override it.
 *
 * We wrote this ourselves instead of using a third-party framework because the domain is small:
 * one page of code is easier to read and defend than a library with features we would never use.
 *
 * inherited sharing: the base class does no data access; subclasses declare their own sharing.
 */
public inherited sharing virtual class TriggerHandler {
  // Lowercased handler class names bypassed for the rest of this transaction.
  private static Set<String> bypassedHandlers = new Set<String>();

  // Lets tests drive run() without a real trigger. Null means "use Trigger.operationType".
  @TestVisible
  private System.TriggerOperation operationType;

  private final String handlerName;

  // String.valueOf(this) is "ClassName:[field=value, ...]"; the part before the colon is the concrete
  // subclass name, so the bypass key always matches the class without each handler repeating it.
  // Worked out once, here, rather than on every run(): String.valueOf(this) prints the instance's
  // fields, and at construction time the subclass's fields are not yet populated, so it stays cheap.
  public TriggerHandler() {
    handlerName = normalize(String.valueOf(this).substringBefore(':'));
  }

  public void run() {
    if (
      Automation_Bypass__c.getInstance().Bypass_Triggers__c == true ||
      isBypassed(handlerName)
    ) {
      return;
    }

    System.TriggerOperation context = operationType != null
      ? operationType
      : Trigger.operationType;
    switch on context {
      when BEFORE_INSERT {
        beforeInsert();
      }
      when BEFORE_UPDATE {
        beforeUpdate();
      }
      when BEFORE_DELETE {
        beforeDelete();
      }
      when AFTER_INSERT {
        afterInsert();
      }
      when AFTER_UPDATE {
        afterUpdate();
      }
      when AFTER_DELETE {
        afterDelete();
      }
      when AFTER_UNDELETE {
        afterUndelete();
      }
    }
  }

  public static void bypass(String handlerName) {
    bypassedHandlers.add(normalize(handlerName));
  }

  public static void clearBypass(String handlerName) {
    bypassedHandlers.remove(normalize(handlerName));
  }

  public static Boolean isBypassed(String handlerName) {
    return bypassedHandlers.contains(normalize(handlerName));
  }

  public static void clearAllBypasses() {
    bypassedHandlers.clear();
  }

  private static String normalize(String handlerName) {
    return handlerName?.toLowerCase();
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
}
