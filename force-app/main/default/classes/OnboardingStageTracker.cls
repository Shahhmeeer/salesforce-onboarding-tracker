/**
 * Stage tracking (spec 8): one Onboarding_Stage__c row per stage an onboarding has reached, holding
 * when the stage was first reached (set once, never changed), how many times it was entered, and
 * total days spent in it across every visit, so rework shows up as time in the stage it went back to.
 *
 * On insert: open a row for the onboarding's starting stage (Kickoff Scheduled).
 * On a stage change X -> Y: close X (add the visit's days to Completed_Visit_Days__c, clear
 * Current_Visit_Started__c), then open Y (create it, or add a visit to the existing row without
 * touching First_Reached__c). One query for the existing rows and one upsert on Unique_Key__c for
 * the whole batch.
 *
 * Re-processing guard: a change is skipped when Y's row is already open, which means this change was
 * already recorded in this transaction (for example when a roll-up recalculation re-saves the
 * onboarding). The guard reads the rows rather than a static set, so it stays correct when a
 * partially successful bulk save is rolled back and retried.
 *
 * without sharing, system mode: CSMs can only read stage rows; automation writes them on their behalf
 * (spec 4.5, 10.3).
 */
public without sharing class OnboardingStageTracker {
  private static final Decimal MILLISECONDS_PER_DAY = 86400000;

  // Lets tests move time forward without waiting (spec 8.4).
  @TestVisible
  private static Datetime nowOverride;

  private static Datetime now() {
    return nowOverride != null ? nowOverride : Datetime.now();
  }

  private static Map<String, String> stageLabels;

  // Opens the first stage row for each new onboarding.
  public static void trackNewOnboardings(List<Onboarding__c> onboardings) {
    Datetime now = now();
    List<Onboarding_Stage__c> rows = new List<Onboarding_Stage__c>();
    for (Onboarding__c onboarding : onboardings) {
      rows.add(newRow(onboarding.Id, onboarding.Stage__c, now));
    }
    if (!rows.isEmpty()) {
      // System mode: CSMs and sales users cannot create stage rows; automation does it for them.
      insert as system rows;
    }
  }

  // Closes the old stage's row and opens the new one for every onboarding whose stage changed.
  public static void trackStageChanges(
    List<Onboarding__c> onboardings,
    Map<Id, Onboarding__c> oldMap
  ) {
    List<Onboarding__c> changed = new List<Onboarding__c>();
    Set<String> keys = new Set<String>();
    for (Onboarding__c onboarding : onboardings) {
      String oldStage = oldMap.get(onboarding.Id).Stage__c;
      if (onboarding.Stage__c != oldStage) {
        changed.add(onboarding);
        keys.add(uniqueKey(onboarding.Id, oldStage));
        keys.add(uniqueKey(onboarding.Id, onboarding.Stage__c));
      }
    }
    if (changed.isEmpty()) {
      return;
    }

    Map<String, Onboarding_Stage__c> existing = new Map<String, Onboarding_Stage__c>();
    // System mode: rows must be read whoever moved the stage, to close and reopen them (spec 8.1).
    for (Onboarding_Stage__c row : [
      SELECT
        Id,
        Unique_Key__c,
        Current_Visit_Started__c,
        Completed_Visit_Days__c,
        Visit_Count__c
      FROM Onboarding_Stage__c
      WHERE Unique_Key__c IN :keys
      WITH SYSTEM_MODE
    ]) {
      existing.put(row.Unique_Key__c, row);
    }

    Datetime now = now();
    List<Onboarding_Stage__c> rows = new List<Onboarding_Stage__c>();
    for (Onboarding__c onboarding : changed) {
      String oldKey = uniqueKey(
        onboarding.Id,
        oldMap.get(onboarding.Id).Stage__c
      );
      String newKey = uniqueKey(onboarding.Id, onboarding.Stage__c);
      Onboarding_Stage__c oldRow = existing.get(oldKey);
      Onboarding_Stage__c newRow = existing.get(newKey);

      if (newRow != null && newRow.Current_Visit_Started__c != null) {
        continue; // Already recorded in this transaction.
      }

      // An onboarding saved with automation off may have no row for the stage it is leaving.
      if (oldRow != null && oldRow.Current_Visit_Started__c != null) {
        rows.add(closeVisit(oldRow, now));
      }

      if (newRow == null) {
        rows.add(newRow(onboarding.Id, onboarding.Stage__c, now));
      } else {
        rows.add(reopen(newRow, now));
      }
    }
    if (!rows.isEmpty()) {
      // System mode: CSMs can only read stage rows; automation writes them on their behalf.
      upsert as system rows Onboarding_Stage__c.Unique_Key__c;
    }
  }

  private static Onboarding_Stage__c newRow(
    Id onboardingId,
    String stage,
    Datetime now
  ) {
    return new Onboarding_Stage__c(
      Name = stageLabel(stage),
      Onboarding__c = onboardingId,
      Stage__c = stage,
      Unique_Key__c = uniqueKey(onboardingId, stage),
      First_Reached__c = now,
      Current_Visit_Started__c = now,
      Visit_Count__c = 1,
      Completed_Visit_Days__c = 0
    );
  }

  // Only the fields that change, so First_Reached__c and the master-detail are never written.
  // The total stays unrounded; Days_In_Stage__c rounds once for display (spec A28).
  private static Onboarding_Stage__c closeVisit(
    Onboarding_Stage__c row,
    Datetime now
  ) {
    Decimal visitDays =
      (now.getTime() - row.Current_Visit_Started__c.getTime()) /
      MILLISECONDS_PER_DAY;
    Decimal completed = row.Completed_Visit_Days__c == null
      ? 0
      : row.Completed_Visit_Days__c;
    return new Onboarding_Stage__c(
      Unique_Key__c = row.Unique_Key__c,
      Completed_Visit_Days__c = (completed + visitDays).setScale(10),
      Current_Visit_Started__c = null
    );
  }

  private static Onboarding_Stage__c reopen(
    Onboarding_Stage__c row,
    Datetime now
  ) {
    Decimal visits = row.Visit_Count__c == null ? 0 : row.Visit_Count__c;
    return new Onboarding_Stage__c(
      Unique_Key__c = row.Unique_Key__c,
      Visit_Count__c = visits + 1,
      Current_Visit_Started__c = now
    );
  }

  // String.valueOf(Id) is always the 18-character Id.
  @TestVisible
  private static String uniqueKey(Id onboardingId, String stage) {
    return String.valueOf(onboardingId) + '-' + stage;
  }

  // The stage's picklist label, e.g. "QA / Review" for QA_Review.
  @TestVisible
  private static String stageLabel(String stage) {
    if (stageLabels == null) {
      stageLabels = new Map<String, String>();
      for (
        Schema.PicklistEntry entry : Onboarding_Stage__c.Stage__c.getDescribe()
          .getPicklistValues()
      ) {
        stageLabels.put(entry.getValue(), entry.getLabel());
      }
    }
    return stageLabels.containsKey(stage) ? stageLabels.get(stage) : stage;
  }
}
