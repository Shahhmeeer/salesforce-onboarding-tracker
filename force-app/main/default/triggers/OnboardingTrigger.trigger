/**
 * The only trigger on Onboarding__c. Sets defaults and the name, assigns owners, tracks stages and
 * alerts CS managers about the backlog. All logic lives in OnboardingTriggerHandler.
 */
trigger OnboardingTrigger on Onboarding__c(
  before insert,
  before update,
  after insert,
  after update
) {
  new OnboardingTriggerHandler().run();
}
