/**
 * The only trigger on Opportunity. Creates, holds, cancels and reactivates onboardings when deals
 * are won, reopened or lost. All logic lives in OpportunityTriggerHandler.
 */
trigger OpportunityTrigger on Opportunity(after insert, after update) {
  new OpportunityTriggerHandler().run();
}
