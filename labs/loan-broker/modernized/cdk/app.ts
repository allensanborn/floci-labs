#!/usr/bin/env node
import * as cdk from "aws-cdk-lib";
import { RecipientListStack } from "./recipient-list-stack";
import { PubSubStack } from "./pubsub-stack";

const app = new cdk.App();

const env = {
  account: process.env.CDK_DEFAULT_ACCOUNT,
  region: process.env.CDK_DEFAULT_REGION,
};

for (const stack of [
  new RecipientListStack(app, "LoanBroker-Modern-RecipientList", { env }),
  new PubSubStack(app, "LoanBroker-Modern-PubSub", { env }),
]) {
  cdk.Tags.of(stack).add("Project", "Floci Labs Loan Broker");
  cdk.Tags.of(stack).add("Track", "modernized");
}
