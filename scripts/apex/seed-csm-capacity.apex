// Gives every active user with the Onboarding_CSM permission set a CSM Capacity record, if they
// do not have one yet (spec 3.4, 14.1).
//
// Demo limits in name order: 5, 7, 7, 10. Any extra CSM gets 5. Existing records are left alone,
// so a limit changed by a manager is never overwritten. No usernames or Ids: users are found by
// their permission set.
//
// Safe to run twice. Run after create-demo-users.apex:
//   sf apex run --file scripts/apex/seed-csm-capacity.apex

final String CSM_PERMISSION_SET = 'Onboarding_CSM';
final List<Integer> DEMO_LIMITS = new List<Integer>{ 5, 7, 7, 10 };
final Integer EXTRA_LIMIT = 5;

List<PermissionSetAssignment> csmAssignments = [
  SELECT AssigneeId, Assignee.Name
  FROM PermissionSetAssignment
  WHERE PermissionSet.Name = :CSM_PERMISSION_SET AND Assignee.IsActive = true
  WITH USER_MODE
  ORDER BY Assignee.Name, AssigneeId
];

Set<Id> csmIds = new Set<Id>();
for (PermissionSetAssignment psa : csmAssignments) {
  csmIds.add(psa.AssigneeId);
}

Set<Id> withCapacity = new Set<Id>();
for (CSM_Capacity__c capacity : [
  SELECT User__c
  FROM CSM_Capacity__c
  WHERE User__c IN :csmIds
  WITH USER_MODE
]) {
  withCapacity.add(capacity.User__c);
}

List<CSM_Capacity__c> toInsert = new List<CSM_Capacity__c>();
Integer position = 0;
for (PermissionSetAssignment psa : csmAssignments) {
  Integer maxActive = position < DEMO_LIMITS.size() ? DEMO_LIMITS[position] : EXTRA_LIMIT;
  position++;
  if (withCapacity.contains(psa.AssigneeId)) {
    continue;
  }
  toInsert.add(
    new CSM_Capacity__c(User__c = psa.AssigneeId, Is_Active__c = true, Max_Active_Onboardings__c = maxActive)
  );
}
insert as user toInsert;

System.debug(
  LoggingLevel.ERROR,
  'CSM capacity: ' + csmAssignments.size() + ' CSMs found, ' + toInsert.size() + ' capacity records created.'
);
