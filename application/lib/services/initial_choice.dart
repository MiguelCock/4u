/// Which of [rows] a form's dropdown starts on: [preferred] (the admin's
/// current filter, or what was used last) while it's still there, else the
/// first row, else none.
String? initialChoice(List<Map<String, dynamic>> rows, String? preferred) {
  if (preferred != null && rows.any((r) => r['id'] == preferred)) {
    return preferred;
  }
  return rows.isEmpty ? null : rows.first['id'] as String?;
}
