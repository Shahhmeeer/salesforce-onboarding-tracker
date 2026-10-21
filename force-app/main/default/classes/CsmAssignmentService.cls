/**
 * Assigns new onboardings to CSMs (spec 7). Each onboarding goes to the eligible CSM with the fewest
 * onboardings that count toward capacity. Ties go to the most remaining capacity, then to the user
 * name alphabetically. When nobody has room, it goes to the backlog queue named in Onboarding
 * Setting, and the after-insert step tells CS managers.
 *
 * Eligible: an active CSM_Capacity__c, an active user, and a live count below the maximum (A6).
 * Counts are live, never stored: Counts_Toward_Capacity__c is true for everything except Cancelled
 * and Post-Launch Review, so On Hold still counts (A5, A9).
 *
 * Concurrency: the CSM_Capacity__c rows are locked with FOR UPDATE before counting, so a parallel
 * load waits here and then sees this one's assignments (spec 7.5). Two queries per call for any
 * batch size, plus one queue lookup only when something overflows.
 *
 * without sharing, system mode: the user saving the onboarding (a sales user closing a deal, a CSM
 * on a Platform licence) may not see CSM Capacity records or other people's onboardings, but
 * assignment must see every CSM and count every onboarding (spec 10.3).
 */
public without sharing class CsmAssignmentService {
  private static final String SETTING_NAME = 'Default';
  private static final String QUEUE_TYPE = 'Queue';

  // DeveloperName of the backlog queue. Tests point it at a missing queue to prove the error.
  @TestVisible
  private static String backlogQueueName = Onboarding_Setting__mdt.getInstance(
      SETTING_NAME
    )
    ?.Backlog_Queue_Name__c;

  // Looked up once per transaction, and only when an onboarding overflows.
  private static Id cachedBacklogQueueId;

  /**
   * Sets OwnerId on each onboarding, in list order. Call from before insert, so no DML is needed.
   * Onboardings that overflow get the backlog queue, or an error if the queue does not exist.
   */
  public static void assign(List<Onboarding__c> newOnboardings) {
    if (newOnboardings == null || newOnboardings.isEmpty()) {
      return;
    }
    List<Csm> csms = lockEligibleCsms();
    loadCounts(csms);

    List<Onboarding__c> overflow = new List<Onboarding__c>();
    for (Onboarding__c onboarding : newOnboardings) {
      Csm chosen = pick(csms);
      if (chosen == null) {
        overflow.add(onboarding);
      } else {
        onboarding.OwnerId = chosen.userId;
        chosen.count++;
      }
    }
    if (!overflow.isEmpty()) {
      sendToBacklog(overflow);
    }
  }

  /**
   * The backlog queue Id if assignment has used the backlog in this transaction, otherwise null.
   * Lets the after-insert step find backlog records without a query of its own.
   */
  public static Id backlogQueueId() {
    return cachedBacklogQueueId;
  }

  private static List<Csm> lockEligibleCsms() {
    Map<Id, Csm> byUser = new Map<Id, Csm>();
    // System mode: assignment must see every CSM whoever saves the onboarding (spec 4.5, 10.3).
    for (CSM_Capacity__c capacity : [
      SELECT Id, User__c, User__r.Name, Max_Active_Onboardings__c
      FROM CSM_Capacity__c
      WHERE Is_Active__c = TRUE AND User__r.IsActive = TRUE
      WITH SYSTEM_MODE
      FOR UPDATE
    ]) {
      // User_Key__c normally stops a second record per user. If the flow was bypassed and one got
      // through, the smaller maximum wins, so the CSM is counted once and never over-assigned.
      Csm csm = new Csm(capacity);
      Csm existing = byUser.get(csm.userId);
      if (existing == null || csm.max < existing.max) {
        byUser.put(csm.userId, csm);
      }
    }
    return byUser.values();
  }

  private static void loadCounts(List<Csm> csms) {
    if (csms.isEmpty()) {
      return;
    }
    Map<Id, Csm> byUser = new Map<Id, Csm>();
    for (Csm csm : csms) {
      byUser.put(csm.userId, csm);
    }
    Set<Id> userIds = byUser.keySet();
    // System mode: counts must include every onboarding, including ones the user cannot see.
    for (AggregateResult row : [
      SELECT OwnerId, COUNT(Id) total
      FROM Onboarding__c
      WHERE Counts_Toward_Capacity__c = TRUE AND OwnerId IN :userIds
      WITH SYSTEM_MODE
      GROUP BY OwnerId
    ]) {
      byUser.get((Id) row.get('OwnerId')).count = (Integer) row.get('total');
    }
  }

  private static Csm pick(List<Csm> csms) {
    Csm best;
    for (Csm candidate : csms) {
      if (candidate.hasRoom() && (best == null || candidate.beats(best))) {
        best = candidate;
      }
    }
    return best;
  }

  private static void sendToBacklog(List<Onboarding__c> overflow) {
    if (cachedBacklogQueueId == null) {
      // System mode: the queue is configuration every saving user needs, whatever their access.
      List<Group> queues = [
        SELECT Id
        FROM Group
        WHERE Type = :QUEUE_TYPE AND DeveloperName = :backlogQueueName
        WITH SYSTEM_MODE
        LIMIT 1
      ];
      if (queues.isEmpty()) {
        String message = String.format(
          Label.Onboarding_Backlog_Queue_Missing,
          new List<Object>{ backlogQueueName }
        );
        for (Onboarding__c onboarding : overflow) {
          onboarding.addError(message);
        }
        return;
      }
      cachedBacklogQueueId = queues[0].Id;
    }
    for (Onboarding__c onboarding : overflow) {
      onboarding.OwnerId = cachedBacklogQueueId;
    }
  }

  // One CSM's capacity and live count, updated in memory as records are assigned.
  private class Csm {
    final Id userId;
    final String sortName;
    final Integer max;
    Integer count = 0;

    Csm(CSM_Capacity__c capacity) {
      userId = capacity.User__c;
      sortName = capacity.User__r.Name == null
        ? ''
        : capacity.User__r.Name.toLowerCase();
      max = capacity.Max_Active_Onboardings__c == null
        ? 0
        : capacity.Max_Active_Onboardings__c.intValue();
    }

    Boolean hasRoom() {
      return count < max;
    }

    Integer remaining() {
      return max - count;
    }

    // Fewest onboardings, then most remaining capacity, then name A to Z (spec 7.1). The user Id
    // settles two CSMs with the same name, so the result never depends on query order.
    Boolean beats(Csm other) {
      if (count != other.count) {
        return count < other.count;
      }
      if (remaining() != other.remaining()) {
        return remaining() > other.remaining();
      }
      if (sortName != other.sortName) {
        return sortName.compareTo(other.sortName) < 0;
      }
      return String.valueOf(userId).compareTo(String.valueOf(other.userId)) < 0;
    }
  }
}
