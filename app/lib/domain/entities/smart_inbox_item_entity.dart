class SmartInboxItemEntity {
  const SmartInboxItemEntity({
    required this.id,
    required this.type,
    required this.title,
    required this.status,
    required this.createdAt,
    this.transactionId,
    this.payloadId,
    this.body,
    this.confidence,
  });

  final String id;
  final String? transactionId;
  final String? payloadId;
  final String type;
  final String title;
  final String? body;
  final String status;
  final double? confidence;
  final DateTime createdAt;
}
