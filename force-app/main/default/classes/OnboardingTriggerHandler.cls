/**
 * Defaults and naming for onboardings (spec 6.4, 6.5). The one place that owns onboarding defaults,
 * whether the onboarding came from a won deal or was created by hand (A12).
 *
 * Before insert: copy Opportunity_Key__c and Account__c from the Opportunity, default the target
 * go-live date, Stage and Status, stamp Current_Stage_Entered__c, build the Name, then assign the
 * owner through CsmAssignmentService (spec 7).
 * Before update: re-stamp Current_Stage_Entered__c on a stage change, keep Opportunity_Key__c in
 * step with Opportunity__c (it can only change with validation rules bypassed), and rebuild the Name only
 * when one of its inputs changed (Name, Account, Opportunity, target date). Updates that change
 * neither, such as the save Salesforce makes when a roll-up recalculates, do no work and no queries.
 * After insert / after update: stage rows through OnboardingStageTracker (spec 8). After insert,
 * then one alert to CS managers, queued to run after commit, if any records went to the backlog.
 *
 * Name format: "<Customer> - Go Live <yyyy-MM-dd>", or "... - Go Live TBD" with no target date.
 * Customer is the onboarding's Account name, or the Opportunity name when there is no Account. The
 * customer part is cut so the Name fits 80 characters; the date part is never cut.
 *
 * without sharing: CSMs (on Platform licenses) cannot read Opportunities, and may not see every
 * Account, but the defaults and Name must still be built.
 */
public without sharing class OnboardingTriggerHandler extends TriggerHandler {
  private static final String DEFAULT_STAGE = 'Kickoff_Scheduled';
  private static final String DEFAULT_STATUS = 'Active';
  private static final String SETTING_NAME = 'Default';
  private static final String NAME_SEPARATOR = ' - Go Live ';
  private static final String NO_DATE = 'TBD';
  private static final Integer NAME_MAX_LENGTH = 80;
  private static final String MANAGER_GROUP_TYPE = 'Regular';
  // The Onboarding list view filtered to the backlog queue. The alert opens it.
  private static final String BACKLOG_LIST_VIEW = 'Backlog';

  protected override void beforeInsert() {
    List<Onboarding__c> onboardings = (List<Onboarding__c>) Trigger.new;
    Map<Id, Opportunity> opportunities = queryOpportunities(onboardings);
    Integer defaultDays = defaultDaysToGoLive();
    Datetime now = Datetime.now();

    for (Onboarding__c onboarding : onboardings) {
      Opportunity opp = opportunities.get(onboarding.Opportunity__c);
      onboarding.Opportunity_Key__c = onboarding.Opportunity__c;
      if (opp != null) {
        if (onboarding.Account__c == null) {
          onboarding.Account__c = opp.AccountId;
        }
        if (
          onboarding.Target_Go_Live_Date__c == null &&
          opp.CloseDate != null &&
          defaultDays != null
        ) {
          onboarding.Target_Go_Live_Date__c = opp.CloseDate.addDays(
            defaultDays
          );
        }
      }
      if (onboarding.Stage__c == null) {
        onboarding.Stage__c = DEFAULT_STAGE;
      }
      if (onboarding.Status__c == null) {
        onboarding.Status__c = DEFAULT_STATUS;
      }
      onboarding.Current_Stage_Entered__c = now;
    }
    rebuildNames(onboardings, opportunities);
    CsmAssignmentService.assign(onboardings);
  }

  protected override void beforeUpdate() {
    List<Onboarding__c> onboardings = (List<Onboarding__c>) Trigger.new;
    Map<Id, Onboarding__c> oldMap = (Map<Id, Onboarding__c>) Trigger.oldMap;
    Datetime now = Datetime.now();

    List<Onboarding__c> renamed = new List<Onboarding__c>();
    for (Onboarding__c onboarding : onboardings) {
      Onboarding__c old = oldMap.get(onboarding.Id);
      if (onboarding.Stage__c != old.Stage__c) {
        onboarding.Current_Stage_Entered__c = now;
      }
      if (onboarding.Opportunity__c != old.Opportunity__c) {
        onboarding.Opportunity_Key__c = onboarding.Opportunity__c;
      }
      if (nameInputsChanged(onboarding, old)) {
        renamed.add(onboarding);
      }
    }
    if (!renamed.isEmpty()) {
      rebuildNames(renamed, new Map<Id, Opportunity>());
    }
  }

  // The fields the Name is built from, plus the Name itself so a hand edit is put back.
  private static Boolean nameInputsChanged(
    Onboarding__c onboarding,
    Onboarding__c old
  ) {
    return onboarding.Name != old.Name ||
      onboarding.Account__c != old.Account__c ||
      onboarding.Opportunity__c != old.Opportunity__c ||
      onboarding.Target_Go_Live_Date__c != old.Target_Go_Live_Date__c;
  }

  protected override void afterInsert() {
    OnboardingStageTracker.trackNewOnboardings(
      (List<Onboarding__c>) Trigger.new
    );
    notifyBacklog((List<Onboarding__c>) Trigger.new);
  }

  protected override void afterUpdate() {
    OnboardingStageTracker.trackStageChanges(
      (List<Onboarding__c>) Trigger.new,
      (Map<Id, Onboarding__c>) Trigger.oldMap
    );
  }

  // Queues one alert to the CS managers group for the whole batch, however many records went to the
  // backlog. A Queueable only runs if the save commits, so a partial-success save that Salesforce
  // rolls back and retries queues exactly one alert, from the attempt that sticks. If this
  // transaction cannot queue another job (for example a second chunk inside batch Apex), the alert
  // is skipped rather than failing the save: the onboardings are already safe in the queue (A23).
  private static void notifyBacklog(List<Onboarding__c> onboardings) {
    Id queueId = CsmAssignmentService.backlogQueueId();
    if (queueId == null) {
      return;
    }
    Integer backlogCount = 0;
    for (Onboarding__c onboarding : onboardings) {
      if (onboarding.OwnerId == queueId) {
        backlogCount++;
      }
    }
    if (
      backlogCount == 0 ||
      Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()
    ) {
      return;
    }
    System.enqueueJob(new BacklogAlertJob(backlogCount));
  }

  /**
   * Sends the backlog alert after the onboardings are committed. Skipped, without error, if the
   * managers group or the notification type is missing (A23).
   *
   * without sharing, system mode: runs as the user who saved the onboardings, who may not be able to
   * read the group or the notification type (spec 4.5).
   */
  @TestVisible
  private without sharing class BacklogAlertJob implements Queueable {
    private final Integer backlogCount;

    BacklogAlertJob(Integer backlogCount) {
      this.backlogCount = backlogCount;
    }

    public void execute(QueueableContext context) {
      Onboarding_Setting__mdt setting = Onboarding_Setting__mdt.getInstance(
        SETTING_NAME
      );
      String groupName = setting?.Manager_Group_Name__c;
      String typeName = setting?.Notification_Type_Name__c;
      // System mode: the managers group must be found whoever saved the onboardings (spec 4.5).
      List<Group> managers = [
        SELECT Id
        FROM Group
        WHERE Type = :MANAGER_GROUP_TYPE AND DeveloperName = :groupName
        WITH SYSTEM_MODE
        LIMIT 1
      ];
      // System mode: notification types are setup data the saving user may not be able to read.
      List<CustomNotificationType> types = [
        SELECT Id
        FROM CustomNotificationType
        WHERE DeveloperName = :typeName
        WITH SYSTEM_MODE
        LIMIT 1
      ];
      if (managers.isEmpty() || types.isEmpty()) {
        return;
      }

      Messaging.CustomNotification alert = new Messaging.CustomNotification();
      alert.setNotificationTypeId(types[0].Id);
      alert.setTitle(Label.Onboarding_Backlog_Alert_Title);
      String body = String.format(
        backlogCount == 1
          ? Label.Onboarding_Backlog_Alert_Body_One
          : Label.Onboarding_Backlog_Alert_Body,
        new List<Object>{ backlogCount }
      );
      alert.setBody(body);
      String targetPageRef = backlogListViewPageRef();
      alert.setTargetPageRef(targetPageRef);
      Set<String> recipients = new Set<String>{ managers[0].Id };
      alert.send(recipients);

      lastBacklogAlert = new BacklogAlert(
        backlogCount,
        body,
        targetPageRef,
        recipients
      );
    }
  }

  // A Lightning page reference to the Backlog list view, by API name, so no Ids are stored.
  private static String backlogListViewPageRef() {
    return JSON.serialize(
      new Map<String, Object>{
        'type' => 'standard__objectPage',
        'attributes' => new Map<String, Object>{
          'objectApiName' => String.valueOf(Onboarding__c.SObjectType),
          'actionName' => 'list'
        },
        'state' => new Map<String, Object>{ 'filterName' => BACKLOG_LIST_VIEW }
      }
    );
  }

  // Tests cannot read sent custom notifications, so the job records what it sent.
  @TestVisible
  private static BacklogAlert lastBacklogAlert;

  @TestVisible
  private class BacklogAlert {
    @TestVisible
    final Integer backlogCount;
    @TestVisible
    final String body;
    @TestVisible
    final String targetPageRef;
    @TestVisible
    final Set<String> recipientIds;

    BacklogAlert(
      Integer backlogCount,
      String body,
      String targetPageRef,
      Set<String> recipientIds
    ) {
      this.backlogCount = backlogCount;
      this.body = body;
      this.targetPageRef = targetPageRef;
      this.recipientIds = recipientIds;
    }
  }

  private static Map<Id, Opportunity> queryOpportunities(
    List<Onboarding__c> onboardings
  ) {
    Set<Id> opportunityIds = new Set<Id>();
    for (Onboarding__c onboarding : onboardings) {
      if (onboarding.Opportunity__c != null) {
        opportunityIds.add(onboarding.Opportunity__c);
      }
    }
    if (opportunityIds.isEmpty()) {
      return new Map<Id, Opportunity>();
    }
    // System mode: CSMs cannot read Opportunities, but defaults and the Name need them (spec 4.5).
    return new Map<Id, Opportunity>(
      [
        SELECT Id, Name, CloseDate, AccountId, Account.Name
        FROM Opportunity
        WHERE Id IN :opportunityIds
        WITH SYSTEM_MODE
      ]
    );
  }

  private static Integer defaultDaysToGoLive() {
    Onboarding_Setting__mdt setting = Onboarding_Setting__mdt.getInstance(
      SETTING_NAME
    );
    return setting?.Default_Days_To_Go_Live__c?.intValue();
  }

  // Looks up only the names not already known from the Opportunities passed in: Account names for
  // onboardings with an Account, Opportunity names for those without. At most two queries.
  private static void rebuildNames(
    List<Onboarding__c> onboardings,
    Map<Id, Opportunity> knownOpportunities
  ) {
    Map<Id, String> accountNames = new Map<Id, String>();
    Map<Id, String> opportunityNames = new Map<Id, String>();
    for (Opportunity opp : knownOpportunities.values()) {
      opportunityNames.put(opp.Id, opp.Name);
      if (opp.AccountId != null) {
        accountNames.put(opp.AccountId, opp.Account.Name);
      }
    }

    Set<Id> missingAccountIds = new Set<Id>();
    Set<Id> missingOpportunityIds = new Set<Id>();
    for (Onboarding__c onboarding : onboardings) {
      if (onboarding.Account__c != null) {
        if (!accountNames.containsKey(onboarding.Account__c)) {
          missingAccountIds.add(onboarding.Account__c);
        }
      } else if (
        onboarding.Opportunity__c != null &&
        !opportunityNames.containsKey(onboarding.Opportunity__c)
      ) {
        missingOpportunityIds.add(onboarding.Opportunity__c);
      }
    }

    if (!missingAccountIds.isEmpty()) {
      // System mode: CSMs may not be able to see the Account, but the Name needs it (spec 4.5).
      for (Account account : [
        SELECT Id, Name
        FROM Account
        WHERE Id IN :missingAccountIds
        WITH SYSTEM_MODE
      ]) {
        accountNames.put(account.Id, account.Name);
      }
    }
    if (!missingOpportunityIds.isEmpty()) {
      // System mode: CSMs cannot read Opportunities, but the Name needs it (spec 4.5).
      for (Opportunity opp : [
        SELECT Id, Name
        FROM Opportunity
        WHERE Id IN :missingOpportunityIds
        WITH SYSTEM_MODE
      ]) {
        opportunityNames.put(opp.Id, opp.Name);
      }
    }

    for (Onboarding__c onboarding : onboardings) {
      String customer = onboarding.Account__c != null
        ? accountNames.get(onboarding.Account__c)
        : opportunityNames.get(onboarding.Opportunity__c);
      onboarding.Name = buildName(customer, onboarding.Target_Go_Live_Date__c);
    }
  }

  // String.valueOf(Date) is always yyyy-MM-dd, whatever the user's locale.
  @TestVisible
  private static String buildName(String customer, Date targetDate) {
    String suffix =
      NAME_SEPARATOR +
      (targetDate == null ? NO_DATE : String.valueOf(targetDate));
    String customerPart = (customer == null ? '' : customer)
      .left(NAME_MAX_LENGTH - suffix.length());
    return customerPart + suffix;
  }
}
