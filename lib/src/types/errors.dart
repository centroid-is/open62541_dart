class Inactivity extends Error {}

class SubscriptionDeleted extends Error {
  final int subscriptionId;
  SubscriptionDeleted(this.subscriptionId);

  @override
  String toString() => 'SubscriptionDeleted(subscriptionId: $subscriptionId)';
}

class SecureChannelClosed extends Error {}
