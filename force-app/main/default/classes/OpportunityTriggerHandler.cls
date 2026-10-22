/**
 * Keeps onboardings in step with their deals (spec 6.3).
 *
 * - Won (on insert, or IsWon turned true): create a bare onboarding if none exists. If one exists,
 *   is On Hold or Cancelled and is not at Post-Launch Review, set it back to Active and clear the
 *   reason. It keeps its owner and is not checked against capacity (A21).
 * - Reopened after win (IsWon was true, now not closed): put a counting onboarding On Hold.
 * - Lost (becomes closed and not won, on insert or update): cancel a counting onboarding.
 *   Re-saving a deal that was already lost does nothing.
 *
 * Uses IsWon / IsClosed, never stage names, so renamed or extra won stages still work. One query,
 * one insert, one update for any number of Opportunities, plus one query only when an insert
 * hits a duplicate. Both writes allow partial success: a row that fails puts an error on its own
 * Opportunity, so one bad onboarding does not fail the other deals in a batch. The handler only sets Opportunity__c on
 * new onboardings; OnboardingTriggerHandler owns every default.
 *
 * without sharing: the user closing the deal is usually a sales user with no access to onboardings,
 * and the onboarding must still be created and kept in step.
 */
public without sharing class OpportunityTriggerHandler extends TriggerHandler {
  private static final String STATUS_ACTIVE = 'Active';
  private static final String STATUS_ON_HOLD = 'On_Hold';
  private static final String STATUS_CANCELLED = 'Cancelled';
  private static final String STAGE_POST_LAUNCH_REVIEW = 'Post_Launch_Review';

  // Test-only: makes every new onboarding fail a real validation rule (On Hold with no reason), so a
  // test can prove that a non-duplicate insert error fails the Opportunity save.
  @TestVisible
  private static Boolean simulateInsertFailure = false;

  protected override void afterInsert() {
    syncOnboardings((List<Opportunity>) Trigger.new, null);
  }

  protected override void afterUpdate() {
    syncOnboardings(
      (List<Opportunity>) Trigger.new,
      (Map<Id, Opportunity>) Trigger.oldMap
    );
  }

  private void syncOnboardings(
    List<Opportunity> opportunities,
    Map<Id, Opportunity> oldMap
  ) {
    List<Opportunity> won = new List<Opportunity>();
    List<Opportunity> reopened = new List<Opportunity>();
    List<Opportunity> lost = new List<Opportunity>();
    Set<String> keys = new Set<String>();

    for (Opportunity opp : opportunities) {
      Opportunity old = oldMap?.get(opp.Id);
      if (opp.IsWon && (old == null || !old.IsWon)) {
        won.add(opp);
      } else if (old != null && old.IsWon && !opp.IsClosed) {
        reopened.add(opp);
      } else if (isLost(opp) && (old == null || !isLost(old))) {
        // Only when the deal becomes lost: re-saving a lost deal leaves its onboarding alone.
        lost.add(opp);
      } else {
        continue;
      }
      keys.add(opp.Id);
    }
    if (keys.isEmpty()) {
      return;
    }

    Map<String, Onboarding__c> onboardingByKey = new Map<String, Onboarding__c>();
    // System mode: the user saving the deal may have no access to onboardings (spec 4.5).
    for (Onboarding__c onboarding : [
      SELECT
        Id,
        Opportunity_Key__c,
        Status__c,
        Stage__c,
        Counts_Toward_Capacity__c
      FROM Onboarding__c
      WHERE Opportunity_Key__c IN :keys
      WITH SYSTEM_MODE
    ]) {
      onboardingByKey.put(onboarding.Opportunity_Key__c, onboarding);
    }

    List<Onboarding__c> toInsert = new List<Onboarding__c>();
    List<Opportunity> insertedFor = new List<Opportunity>();
    List<Onboarding__c> toUpdate = new List<Onboarding__c>();
    List<Opportunity> updatedFor = new List<Opportunity>();

    for (Opportunity opp : won) {
      Onboarding__c existing = onboardingByKey.get(opp.Id);
      if (existing == null) {
        toInsert.add(newOnboarding(opp.Id));
        insertedFor.add(opp);
      } else if (canReactivate(existing)) {
        toUpdate.add(withStatus(existing.Id, STATUS_ACTIVE, null));
        updatedFor.add(opp);
      }
    }
    for (Opportunity opp : reopened) {
      Onboarding__c existing = onboardingByKey.get(opp.Id);
      if (existing != null && existing.Counts_Toward_Capacity__c) {
        toUpdate.add(
          withStatus(
            existing.Id,
            STATUS_ON_HOLD,
            System.Label.Onboarding_Reason_Deal_Reopened
          )
        );
        updatedFor.add(opp);
      }
    }
    for (Opportunity opp : lost) {
      Onboarding__c existing = onboardingByKey.get(opp.Id);
      if (existing != null && existing.Counts_Toward_Capacity__c) {
        toUpdate.add(
          withStatus(
            existing.Id,
            STATUS_CANCELLED,
            System.Label.Onboarding_Reason_Deal_Lost
          )
        );
        updatedFor.add(opp);
      }
    }

    if (!toUpdate.isEmpty()) {
      updateOnboardings(toUpdate, updatedFor);
    }
    if (!toInsert.isEmpty()) {
      insertOnboardings(toInsert, insertedFor);
    }
  }

  private static Boolean isLost(Opportunity opp) {
    return opp.IsClosed && !opp.IsWon;
  }

  // Reactivation cannot use Counts_Toward_Capacity__c: it is false for every Cancelled onboarding.
  // Finished onboardings (Post-Launch Review) are left alone (spec 6.3).
  private static Boolean canReactivate(Onboarding__c onboarding) {
    return (onboarding.Status__c == STATUS_ON_HOLD ||
      onboarding.Status__c == STATUS_CANCELLED) &&
      onboarding.Stage__c != STAGE_POST_LAUNCH_REVIEW;
  }

  private static Onboarding__c newOnboarding(Id opportunityId) {
    Onboarding__c onboarding = new Onboarding__c(
      Opportunity__c = opportunityId
    );
    if (simulateInsertFailure) {
      onboarding.Status__c = STATUS_ON_HOLD;
    }
    return onboarding;
  }

  private static Onboarding__c withStatus(
    Id onboardingId,
    String status,
    String reason
  ) {
    return new Onboarding__c(
      Id = onboardingId,
      Status__c = status,
      Status_Reason__c = reason
    );
  }

  // Partial success so one bad row does not block the rest. A row that failed only with
  // DUPLICATE_VALUE is ignored if an onboarding now exists for its Opportunity key: another
  // transaction created it first, which is fine. The platform masks the field in duplicate errors
  // ("<unknown>"), so the re-query is the reliable check. Any other failure fails that
  // Opportunity's save: a won deal must never end up silently without an onboarding.
  @TestVisible
  private static void insertOnboardings(
    List<Onboarding__c> onboardings,
    List<Opportunity> opportunities
  ) {
    // System mode: the user saving the deal may have no access to onboardings (spec 4.5).
    List<Database.SaveResult> results = Database.insert(
      onboardings,
      false,
      AccessLevel.SYSTEM_MODE
    );

    Set<String> duplicateKeys = new Set<String>();
    for (Integer i = 0; i < results.size(); i++) {
      if (
        !results[i].isSuccess() && onlyDuplicateErrors(results[i].getErrors())
      ) {
        duplicateKeys.add(onboardings[i].Opportunity__c);
      }
    }
    Set<String> existingKeys = new Set<String>();
    if (!duplicateKeys.isEmpty()) {
      // System mode: must see onboardings the saving user cannot, to confirm the duplicate.
      for (Onboarding__c existing : [
        SELECT Opportunity_Key__c
        FROM Onboarding__c
        WHERE Opportunity_Key__c IN :duplicateKeys
        WITH SYSTEM_MODE
      ]) {
        existingKeys.add(existing.Opportunity_Key__c);
      }
    }

    for (Integer i = 0; i < results.size(); i++) {
      Database.SaveResult result = results[i];
      Boolean alreadyCreated =
        onlyDuplicateErrors(result.getErrors()) &&
        existingKeys.contains(onboardings[i].Opportunity__c);
      if (result.isSuccess() || alreadyCreated) {
        continue;
      }
      opportunities[i]
        .addError(
          String.format(
            System.Label.Onboarding_Creation_Failed,
            new List<Object>{ firstMessage(result.getErrors()) }
          )
        );
    }
  }

  // Partial success, like the insert: a status change that fails (a row lock, or a validation rule
  // added later) fails only its own Opportunity's save, with the reason, not the whole batch.
  @TestVisible
  private static void updateOnboardings(
    List<Onboarding__c> onboardings,
    List<Opportunity> opportunities
  ) {
    // System mode: the user saving the deal may have no access to onboardings (spec 4.5).
    List<Database.SaveResult> results = Database.update(
      onboardings,
      false,
      AccessLevel.SYSTEM_MODE
    );
    for (Integer i = 0; i < results.size(); i++) {
      if (!results[i].isSuccess()) {
        opportunities[i]
          .addError(
            String.format(
              System.Label.Onboarding_Status_Update_Failed,
              new List<Object>{ firstMessage(results[i].getErrors()) }
            )
          );
      }
    }
  }

  private static Boolean onlyDuplicateErrors(List<Database.Error> errors) {
    if (errors.isEmpty()) {
      return false;
    }
    for (Database.Error error : errors) {
      if (error.getStatusCode() != StatusCode.DUPLICATE_VALUE) {
        return false;
      }
    }
    return true;
  }

  private static String firstMessage(List<Database.Error> errors) {
    for (Database.Error error : errors) {
      if (error.getStatusCode() != StatusCode.DUPLICATE_VALUE) {
        return error.getMessage();
      }
    }
    return errors[0].getMessage();
  }
}
