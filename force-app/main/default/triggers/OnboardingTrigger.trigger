/**
 * The only trigger on Onboarding__c. Sets defaults and the name, and (from later steps) assigns
 * owners and tracks stages. All logic lives in OnboardingTriggerHandler.
 */
trigger OnboardingTrigger on Onboarding__c(
  before insert,
  before update,
  after insert,
  after update
) {
  new OnboardingTriggerHandler().run();
}
