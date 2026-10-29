/// The typed chat thread (PLAN.md decision 2026-10-28, build plan B2).
///
/// A list of entries `{role, text, sources?, offer?}` kept in the private
/// store under [StoreKeys.chatThread]. Consecutive assistant sentences merge
/// into one bubble; sources and offers close a bubble. Entries hold the
/// user's own words, so they are never logged.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../voice/voice_session.dart';
import 'app_controller.dart';
import 'persistence.dart';

enum ChatRole { user, assistant }

/// An offer bubble's state. Only [open] offers take a tap.
enum OfferState { open, accepted, declined, closed }

class ChatOffer {
  const ChatOffer(this.id, [this.state = OfferState.open]);
  final String id;
  final OfferState state;
  bool get isOpen => state == OfferState.open;
}

@immutable
class ChatEntry {
  const ChatEntry({required this.role, required this.text, this.sources, this.offer});
  final ChatRole role;
  final String text;

  /// "Sources: A · B" after a council answer.
  final String? sources;

  /// Set on a yes/no question ("Open your logs?").
  final ChatOffer? offer;

  ChatEntry copyWith({String? text, String? sources, ChatOffer? offer}) => ChatEntry(
      role: role, text: text ?? this.text, sources: sources ?? this.sources, offer: offer ?? this.offer);

  Map<String, Object> toJson() => {
        'role': role.name,
        'text': text,
        'sources': ?sources,
        if (offer != null) 'offer': {'id': offer!.id, 'state': offer!.state.name},
      };

  /// Null for anything malformed. An offer that was still open is closed:
  /// no offer survives a restart.
  static ChatEntry? fromJson(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    final role = ChatRole.values.asNameMap()[j['role']];
    final text = j['text'];
    if (role == null || text is! String) return null;
    final s = j['sources'];
    final o = j['offer'];
    ChatOffer? offer;
    if (o is Map<String, dynamic> && o['id'] is String) {
      final st = OfferState.values.asNameMap()[o['state']] ?? OfferState.closed;
      offer = ChatOffer(o['id'] as String, st == OfferState.open ? OfferState.closed : st);
    }
    return ChatEntry(role: role, text: text, sources: s is String ? s : null, offer: offer);
  }
}

class ChatThread extends ChangeNotifier {
  ChatThread({this.store, this.maxEntries = 200});

  final StateStore? store;

  /// Oldest entries are dropped past this many.
  final int maxEntries;

  final _entries = <ChatEntry>[];
  Future<void> _writes = Future.value();

  List<ChatEntry> get entries => List.unmodifiable(_entries);

  /// The last user entry and everything after it (the latest exchange), or
  /// the trailing assistant entries when the user has not typed yet.
  List<ChatEntry> get latestExchange {
    final i = _entries.lastIndexWhere((e) => e.role == ChatRole.user);
    if (i >= 0) return List.unmodifiable(_entries.sublist(i));
    return List.unmodifiable(_entries.length <= 2 ? _entries : _entries.sublist(_entries.length - 2));
  }

  /// Completes when every write so far has finished.
  Future<void> get saved => _writes;

  Future<void> load() async {
    final raw = await store?.getString(StoreKeys.chatThread);
    if (raw == null) return;
    try {
      final j = jsonDecode(raw);
      if (j is! List) return;
      _entries
        ..clear()
        ..addAll(j.map(ChatEntry.fromJson).whereType<ChatEntry>());
    } on FormatException {
      return;
    }
    notifyListeners();
  }

  /// A typed message. Any offer still open is closed (a new turn cancels it;
  /// the flow that owns the offer may then mark it accepted or declined).
  void addUser(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    for (var i = 0; i < _entries.length; i++) {
      final o = _entries[i].offer;
      if (o != null && o.isOpen) _entries[i] = _entries[i].copyWith(offer: ChatOffer(o.id, OfferState.closed));
    }
    _add(ChatEntry(role: ChatRole.user, text: t));
  }

  /// One assistant sentence; merged into the last bubble when that is an
  /// assistant bubble without sources or an offer.
  void addAssistant(String sentence) {
    final t = sentence.trim();
    if (t.isEmpty) return;
    final last = _entries.isEmpty ? null : _entries.last;
    if (last != null && last.role == ChatRole.assistant && last.sources == null && last.offer == null) {
      _entries[_entries.length - 1] = last.copyWith(text: '${last.text} $t');
      _changed();
      return;
    }
    _add(ChatEntry(role: ChatRole.assistant, text: t));
  }

  /// A yes/no question in its own bubble.
  void addOffer(String text, String offerId) =>
      _add(ChatEntry(role: ChatRole.assistant, text: text.trim(), offer: ChatOffer(offerId)));

  /// Sets the state of offer [offerId]. No-op when it is not in the thread.
  void closeOffer(String offerId, OfferState state) {
    final i = _entries.lastIndexWhere((e) => e.offer?.id == offerId);
    if (i < 0 || _entries[i].offer!.state == state) return;
    _entries[i] = _entries[i].copyWith(offer: ChatOffer(offerId, state));
    _changed();
  }

  /// Attaches council sources to the last assistant bubble (or adds one).
  void attachSources(String sources) {
    final i = _entries.lastIndexWhere((e) => e.role == ChatRole.assistant);
    if (i < 0 || _entries[i].offer != null) {
      _add(ChatEntry(role: ChatRole.assistant, text: '', sources: sources));
      return;
    }
    _entries[i] = _entries[i].copyWith(sources: sources);
    _changed();
  }

  void _add(ChatEntry e) {
    _entries.add(e);
    if (_entries.length > maxEntries) _entries.removeRange(0, _entries.length - maxEntries);
    _changed();
  }

  void _changed() {
    notifyListeners();
    final s = store;
    if (s == null) return;
    final raw = jsonEncode([for (final e in _entries) e.toJson()]);
    _writes = _writes.then((_) => s.setString(StoreKeys.chatThread, raw));
  }
}

/// A typed turn: the text goes into [thread] as the user's bubble, then
/// through the voice reducer ([TextSubmitted]) into
/// AppController.handleUtterance, setupHook and routeTurn unchanged.
void submitTypedTurn(AppController controller, ChatThread thread, String text) {
  final t = text.trim();
  if (t.isEmpty) return;
  thread.addUser(t);
  controller.dispatch(TextSubmitted(t));
}
