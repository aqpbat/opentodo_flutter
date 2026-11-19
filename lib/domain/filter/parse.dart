// Filter query language: tokenizer, recursive-descent parser, date expressions
// and the canonical printer. Pure and dependency-free.
// ported from web/src/lib/filter/parse.ts (grammar in docs/filters.md; the Go
// twin is internal/filter/filter.go).
//
//   query   := or
//   or      := and ( "|" and )*
//   and     := not ( "&" not )*
//   not     := "!" not | "(" or ")" | term
//   term    := "@" name | "##" name | "#" name | "p1".."p4"
//            | ("due" | "created" | "deadline" | "start" | "completed") cmp date
//            | keyword | "search:" text | "origin:" value | "energy:" level
//            | "sector:" (relative word | period) | "workspace:" name
//            | "notes:" text | "assigned:" name
//            | "tracked" ["occurrence"] cmp duration
//            | field cmp value | "no" field
//
// Positions in messages are 1-based character columns (UTF-16 code units, as
// in the web client); FilterSyntaxError.offset is the 0-based offset.

import 'calendar.dart';

// ---- tokens ----

/// A comparison operator.
enum Cmp {
  lt('<'),
  le('<='),
  eq('='),
  ge('>='),
  gt('>');

  const Cmp(this.text);
  final String text;

  static Cmp of(String s) => Cmp.values.firstWhere((c) => c.text == s);
}

enum TokenType { and, or, not, lparen, rparen, cmp, label, project, priority, search, origin, assigned, energy, sector, workspace, notes, word, string }

/// One token. `value` holds the name, text or value of the token's kind.
class Token {
  const Token(this.type, this.pos, this.raw, {this.value = '', this.op, this.descendants = false, this.priority = 0});
  final TokenType type;
  final int pos;
  final String raw;
  final String value;
  final Cmp? op;
  final bool descendants;
  final int priority;
}

/// A syntax error with a 0-based offset and the set of things that were expected.
class FilterSyntaxError implements Exception {
  FilterSyntaxError(this.message, this.offset, [this.expected = const []]);
  final String message;
  final int offset;
  final List<String> expected;

  /// 1-based column, as shown in the message.
  int get position => offset + 1;

  @override
  String toString() => message;
}

/// A `sector:` term's value: a relative word ("this-week") or a period in upper case, or null.
String? sectorTermValue(String text) {
  final word = text.trim().toLowerCase().split(RegExp(r'[\s_-]+')).join('-');
  if (sectorWords.contains(word)) return word;
  final period = text.trim().toUpperCase();
  return isSector(period) ? period : null;
}

const Map<String, TokenType> _single = {
  '&': TokenType.and,
  '|': TokenType.or,
  '!': TokenType.not,
  '(': TokenType.lparen,
  ')': TokenType.rparen,
};

/// Characters that end a bare word.
final RegExp _break = RegExp(r'[\s"&|!()<>=]');
final RegExp _space = RegExp(r'\s');

bool _isSpace(String c) => _space.hasMatch(c);

/// Split a query into tokens. Throws FilterSyntaxError for a bad prefix or an unterminated string.
List<Token> tokenize(String src) => _Tokenizer(src).run();

class _Tokenizer {
  _Tokenizer(this.src) : n = src.length;
  final String src;
  final int n;
  int i = 0;
  final List<Token> out = [];

  String readBare() {
    final start = i;
    while (i < n && !_break.hasMatch(src[i])) {
      i++;
    }
    return src.substring(start, i);
  }

  String readString() {
    // src[i] is the opening quote. Backslash escapes the next character.
    final start = i;
    i++;
    final s = StringBuffer();
    while (i < n && src[i] != '"') {
      if (src[i] == r'\' && i + 1 < n) i++;
      s.write(src[i++]);
    }
    if (i >= n) {
      throw FilterSyntaxError('Missing closing quote for the text starting at position ${start + 1}', start, ['"']);
    }
    i++;
    return s.toString();
  }

  String readName(String what, String after, int at) {
    if (i < n && src[i] == '"') return readString();
    final name = readBare();
    if (name.isEmpty) {
      throw FilterSyntaxError('Expected a $what name after "$after" at position ${at + 1}', at, ['$what name']);
    }
    return name;
  }

  /// `search:text`, `search: text` or `search: "several words"`.
  String readPrefixed(String word, String prefix) {
    final text = word.substring(prefix.length);
    if (text.isNotEmpty) return text;
    while (i < n && _isSpace(src[i])) {
      i++;
    }
    return i < n && src[i] == '"' ? readString() : readBare();
  }

  void push(TokenType type, int pos, {String value = ''}) => out.add(Token(type, pos, src.substring(pos, i), value: value));

  bool prefixed(String word, String prefix) => word.length >= prefix.length && word.substring(0, prefix.length).toLowerCase() == prefix;

  List<Token> run() {
    while (i < n) {
      final c = src[i];
      if (_isSpace(c)) {
        i++;
        continue;
      }
      final pos = i;
      final single = _single[c];
      if (single != null) {
        i++;
        out.add(Token(single, pos, c));
        continue;
      }
      if (c == '<' || c == '>' || c == '=') {
        final op = c != '=' && i + 1 < n && src[i + 1] == '=' ? '$c=' : c;
        i += op.length;
        out.add(Token(TokenType.cmp, pos, op, op: Cmp.of(op)));
        continue;
      }
      if (c == '@') {
        i++;
        final name = readName('label', '@', pos);
        push(TokenType.label, pos, value: name);
        continue;
      }
      if (c == '#') {
        final descendants = i + 1 < n && src[i + 1] == '#';
        i += descendants ? 2 : 1;
        final name = readName('project', descendants ? '##' : '#', pos);
        out.add(Token(TokenType.project, pos, src.substring(pos, i), value: name, descendants: descendants));
        continue;
      }
      if (c == '"') {
        final value = readString();
        push(TokenType.string, pos, value: value);
        continue;
      }
      _wordTerm(readBare(), pos);
    }
    return out;
  }

  /// A bare word at `pos`: a prefixed term, a priority or a plain word.
  void _wordTerm(String word, int pos) {
    if (prefixed(word, 'search:') || prefixed(word, 'notes:')) {
      final notes = prefixed(word, 'notes:');
      final text = readPrefixed(word, notes ? 'notes:' : 'search:');
      if (text.isEmpty) {
        throw FilterSyntaxError('Expected text after "${notes ? 'notes:' : 'search:'}" at position ${pos + 1}', pos, ['text']);
      }
      push(notes ? TokenType.notes : TokenType.search, pos, value: text);
      return;
    }
    if (prefixed(word, 'workspace:')) {
      final name = readPrefixed(word, 'workspace:');
      if (name.isEmpty) {
        throw FilterSyntaxError('Expected a workspace name after "workspace:" at position ${pos + 1}', pos, ['workspace name']);
      }
      push(TokenType.workspace, pos, value: name);
      return;
    }
    if (prefixed(word, 'origin:')) {
      final value = readPrefixed(word, 'origin:');
      if (value.isEmpty) {
        throw FilterSyntaxError('Expected a provider or kind after "origin:" at position ${pos + 1}', pos, ['origin']);
      }
      push(TokenType.origin, pos, value: value);
      return;
    }
    if (prefixed(word, 'assigned:')) {
      final name = readPrefixed(word, 'assigned:');
      if (name.isEmpty) throw FilterSyntaxError('Expected a name after "assigned:" at position ${pos + 1}', pos, ['name']);
      push(TokenType.assigned, pos, value: name);
      return;
    }
    if (prefixed(word, 'energy:')) {
      final value = readPrefixed(word, 'energy:').toLowerCase();
      if (value != 'deep' && value != 'medium' && value != 'low') {
        throw FilterSyntaxError('Energy must be deep, medium or low at position ${pos + 1}', pos, ['"deep"', '"medium"', '"low"']);
      }
      push(TokenType.energy, pos, value: value);
      return;
    }
    if (prefixed(word, 'sector:')) {
      var text = readPrefixed(word, 'sector:');
      if (RegExp(r'^(this|next)$', caseSensitive: false).hasMatch(text)) {
        while (i < n && _isSpace(src[i])) {
          i++;
        }
        text = '$text ${readBare()}';
      }
      final value = sectorTermValue(text);
      if (value == null) {
        throw FilterSyntaxError(
            'Unknown time sector "$text" at position ${pos + 1}; use this week, next week, this month, next month, this quarter, next quarter or a period such as 2026-W44',
            pos,
            ['"this week"', '"2026-W44"']);
      }
      push(TokenType.sector, pos, value: value);
      return;
    }
    final pm = RegExp(r'^p([1-4])$', caseSensitive: false).firstMatch(word);
    if (pm != null) {
      out.add(Token(TokenType.priority, pos, word, priority: int.parse(pm.group(1)!)));
      return;
    }
    out.add(Token(TokenType.word, pos, word, value: word));
    return;
  }
}

// ---- AST ----

/// today = 0, tomorrow = 1, yesterday = -1, `N days` = N, `N days ago` = -N; a
/// period is a calendar week or month relative to the current one.
sealed class DateExpr {
  const DateExpr();
}

class RelativeDate extends DateExpr {
  const RelativeDate(this.days);
  final int days;
}

class WeekdayDate extends DateExpr {
  const WeekdayDate(this.day);

  /// 0 = Sunday.
  final int day;
}

class IsoDate extends DateExpr {
  const IsoDate(this.date);
  final String date;
}

class PeriodDate extends DateExpr {
  const PeriodDate(this.unit, this.offset);

  /// 'week' or 'month'.
  final String unit;
  final int offset;
}

/// The right-hand side of a field term; the field's type decides how it compares.
sealed class FieldValueExpr {
  const FieldValueExpr();
}

class NumberValue extends FieldValueExpr {
  const NumberValue(this.value);
  final num value;
}

class BoolValue extends FieldValueExpr {
  const BoolValue(this.value);
  final bool value;
}

class TextValue extends FieldValueExpr {
  const TextValue(this.value);
  final String value;
}

class DateValue extends FieldValueExpr {
  const DateValue(this.date);
  final DateExpr date;
}

/// A parsed query.
sealed class FilterNode {
  const FilterNode();
}

class OrNode extends FilterNode {
  const OrNode(this.items);
  final List<FilterNode> items;
}

class AndNode extends FilterNode {
  const AndNode(this.items);
  final List<FilterNode> items;
}

class NotNode extends FilterNode {
  const NotNode(this.item);
  final FilterNode item;
}

class LabelNode extends FilterNode {
  const LabelNode(this.name, this.pos);
  final String name;
  final int pos;
}

class ProjectNode extends FilterNode {
  const ProjectNode(this.name, this.descendants, this.pos);
  final String name;
  final bool descendants;
  final int pos;
}

class PriorityNode extends FilterNode {
  const PriorityNode(this.value);
  final int value;
}

/// `field op date`; field is due, created, deadline, start or completed.
class DateNode extends FilterNode {
  const DateNode(this.field, this.op, this.date);
  final String field;
  final Cmp op;
  final DateExpr date;
}

/// A keyword such as `overdue` or `no date` (see [filterKeywords]).
class KeywordNode extends FilterNode {
  const KeywordNode(this.keyword);
  final String keyword;
}

class SearchNode extends FilterNode {
  const SearchNode(this.text);
  final String text;
}

/// `notes: text`: the task's description contains text, ignoring case.
class NotesNode extends FilterNode {
  const NotesNode(this.text);
  final String text;
}

/// `origin: value`: the origin's provider, else its kind, equals value ignoring case.
class OriginNode extends FilterNode {
  const OriginNode(this.value);
  final String value;
}

/// `assigned: name`: the viewer (`me`) or a member with that name or email.
class AssignedNode extends FilterNode {
  const AssignedNode(this.name);
  final String name;
}

class EnergyNode extends FilterNode {
  const EnergyNode(this.value);
  final String value;
}

/// `sector: value`: a period, or a relative word resolved on the viewer's day.
class SectorNode extends FilterNode {
  const SectorNode(this.value);
  final String value;
}

class WorkspaceNode extends FilterNode {
  const WorkspaceNode(this.name, this.pos);
  final String name;
  final int pos;
}

/// `name cmp value` over a custom field; `opPos` places type errors.
class FieldNode extends FilterNode {
  const FieldNode(this.name, this.op, this.value, this.pos, this.opPos);
  final String name;
  final Cmp op;
  final FieldValueExpr value;
  final int pos;
  final int opPos;
}

/// `no name`: a project defining the field, no value.
class NoFieldNode extends FilterNode {
  const NoFieldNode(this.name, this.pos);
  final String name;
  final int pos;
}

/// `tracked [occurrence] cmp duration`.
class TrackedNode extends FilterNode {
  const TrackedNode(this.op, this.minutes, {this.occurrence = false});
  final Cmp op;
  final int minutes;
  final bool occurrence;
}

const List<String> weekdays = ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'];
const Set<String> _simpleKeywords = {
  'overdue', 'today', 'tomorrow', 'completed', 'open', 'subtask', 'someday', 'deferred', 'evening', 'morning', //
  'afternoon', 'blocked', 'unblocked', 'available', 'habit', 'origin', 'energy', 'notes', 'sector', 'carried',
  'assigned', 'unassigned',
};
const List<String> _noKeywords = ['date', 'project', 'labels', 'time', 'deadline', 'start', 'origin', 'energy', 'notes', 'sector'];

/// Every keyword a [KeywordNode] can hold.
final Set<String> filterKeywords = {
  ..._simpleKeywords,
  for (final k in _noKeywords) 'no $k',
  'tracked',
  'tracked occurrence',
};
const Set<String> _dateStarts = {'today', 'tomorrow', 'yesterday', 'this', 'last', 'next'};
const Set<String> _dateUnits = {'days', 'week', 'weeks', 'month', 'months'};
const List<String> _cmpExpected = ['"<"', '"<="', '"="', '">="', '">"', '"before"', '"after"'];
final RegExp _digits = RegExp(r'^\d+$');
final RegExp _numberRe = RegExp(r'^-?\d+(\.\d+)?$');

// ---- parser ----

/// The longest query in characters (code points), as MaxQueryLength on the server.
const int maxQueryLength = 4096;

/// The deepest nesting of "(" and "!", as MaxNesting on the server.
const int maxNesting = 64;

/// Parse a query. Returns null for an empty (whitespace-only) query; throws FilterSyntaxError otherwise.
FilterNode? parseFilter(String src) {
  if (src.length > maxQueryLength && src.runes.length > maxQueryLength) {
    throw FilterSyntaxError('Query is too long: ${src.runes.length} characters, at most $maxQueryLength', maxQueryLength);
  }
  final tokens = tokenize(src);
  if (tokens.isEmpty) return null;
  return _Parser(tokens, src.length).run();
}

class _Parser {
  _Parser(this.tokens, this.end);
  final List<Token> tokens;
  final int end;
  int i = 0;
  int depth = 0;

  Token? peek() => i < tokens.length ? tokens[i] : null;
  Token? at(int k) => k < tokens.length ? tokens[k] : null;
  String lower(Token? tok) => tok != null && tok.type == TokenType.word ? tok.value.toLowerCase() : '';

  Never fail(String message, int offset, List<String> expected) => throw FilterSyntaxError(message, offset, expected);

  /// Error for a missing term; `prev` is the operator or parenthesis just consumed, if any.
  Never missingTerm(Token? prev) {
    final token = peek();
    if (prev != null) fail('Expected a term after "${prev.raw}" at position ${prev.pos + 1}', prev.pos, ['term']);
    final at = token?.pos ?? end;
    fail('Expected a term at position ${at + 1}', at, ['term']);
  }

  FilterNode run() {
    final ast = parseOr(null);
    final rest = peek();
    if (rest != null) {
      if (rest.type == TokenType.rparen) fail('Unexpected ")" at position ${rest.pos + 1}', rest.pos, ['"&"', '"|"']);
      fail('Expected "&" or "|" before "${rest.raw}" at position ${rest.pos + 1}', rest.pos, ['"&"', '"|"']);
    }
    return ast;
  }

  FilterNode parseOr(Token? prev) {
    final items = [parseAnd(prev)];
    while (peek()?.type == TokenType.or) {
      items.add(parseAnd(tokens[i++]));
    }
    return items.length == 1 ? items[0] : OrNode(items);
  }

  FilterNode parseAnd(Token? prev) {
    final items = [parseNot(prev)];
    while (peek()?.type == TokenType.and) {
      items.add(parseNot(tokens[i++]));
    }
    return items.length == 1 ? items[0] : AndNode(items);
  }

  void enter(Token tok) {
    if (++depth > maxNesting) {
      fail('Too deeply nested at position ${tok.pos + 1}; use at most $maxNesting levels of "(" and "!"', tok.pos, []);
    }
  }

  FilterNode parseNot(Token? prev) {
    final tok = peek();
    if (tok == null) missingTerm(prev);
    if (tok.type == TokenType.not) {
      i++;
      enter(tok);
      final item = parseNot(tok);
      depth--;
      return NotNode(item);
    }
    if (tok.type == TokenType.lparen) {
      i++;
      enter(tok);
      final inner = parseOr(tok);
      final close = peek();
      if (close == null) fail('Missing ")" at end of query', end, ['")"']);
      if (close.type != TokenType.rparen) {
        fail('Expected "&", "|" or ")" before "${close.raw}" at position ${close.pos + 1}', close.pos, ['"&"', '"|"', '")"']);
      }
      i++;
      depth--;
      return inner;
    }
    return parseTerm(prev);
  }

  FilterNode parseTerm(Token? prev) {
    final tok = peek()!;
    switch (tok.type) {
      case TokenType.label:
        i++;
        return LabelNode(tok.value, tok.pos);
      case TokenType.project:
        i++;
        return ProjectNode(tok.value, tok.descendants, tok.pos);
      case TokenType.priority:
        i++;
        return PriorityNode(tok.priority);
      case TokenType.search:
        i++;
        return SearchNode(tok.value);
      case TokenType.notes:
        i++;
        return NotesNode(tok.value);
      case TokenType.origin:
        i++;
        return OriginNode(tok.value);
      case TokenType.assigned:
        i++;
        return AssignedNode(tok.value);
      case TokenType.energy:
        i++;
        return EnergyNode(tok.value);
      case TokenType.sector:
        i++;
        return SectorNode(tok.value);
      case TokenType.workspace:
        i++;
        return WorkspaceNode(tok.value, tok.pos);
      case TokenType.word:
        return parseWordTerm(tok);
      case TokenType.string:
        // A quoted name followed by a comparison is a field term.
        if (at(i + 1)?.type == TokenType.cmp) {
          i++;
          return parseFieldTerm(tok.value, tok.pos);
        }
        fail('Unexpected text ${tok.raw} at position ${tok.pos + 1}; quote names after "@" or "#", or use search:', tok.pos, ['term']);
      default:
        missingTerm(prev);
    }
  }

  FilterNode parseWordTerm(Token entry) {
    final w = entry.value.toLowerCase();
    i++;
    // `completed` is the state keyword unless a comparison follows.
    final dated = w == 'completed' && (peek()?.type == TokenType.cmp || lower(peek()) == 'before' || lower(peek()) == 'after');
    if (w == 'due' || w == 'created' || w == 'deadline' || w == 'start' || dated) {
      final c = peek();
      Cmp? op;
      if (c?.type == TokenType.cmp) {
        op = c!.op;
      } else if (lower(c) == 'before') {
        op = Cmp.lt;
      } else if (lower(c) == 'after') {
        op = Cmp.gt;
      }
      if (op == null || c == null) {
        fail('Expected a comparison (<, <=, =, >=, >, before or after) after "${entry.raw}" at position ${entry.pos + 1}', entry.pos, _cmpExpected);
      }
      i++;
      return DateNode(w, op, parseDate(c));
    }
    if (w == 'tracked') return parseTracked();
    if (w == 'no') {
      final nt = peek();
      final next = lower(nt);
      if (_noKeywords.contains(next)) {
        i++;
        return KeywordNode('no $next');
      }
      // Any other name is a custom field without a value.
      if (nt != null && (nt.type == TokenType.word || nt.type == TokenType.string)) {
        i++;
        return NoFieldNode(nt.value, nt.pos);
      }
      fail('Expected "date", "project", "labels", "time", "deadline", "start", "origin" or a field name after "no" at position ${entry.pos + 1}',
          entry.pos, [..._noKeywords.map((k) => '"$k"'), 'field name']);
    }
    if (_simpleKeywords.contains(w)) return KeywordNode(w);
    if (RegExp(r'^p\d+$').hasMatch(w)) {
      fail('Priority must be p1, p2, p3 or p4 at position ${entry.pos + 1}', entry.pos, ['"p1"', '"p2"', '"p3"', '"p4"']);
    }
    // Any other word followed by a comparison names a custom field.
    if (peek()?.type == TokenType.cmp) return parseFieldTerm(entry.value, entry.pos);
    fail('Unknown term "${entry.raw}" at position ${entry.pos + 1}', entry.pos, ['term']);
  }

  /// `tracked` [occurrence] [cmp duration], with `tracked` consumed.
  FilterNode parseTracked() {
    var occurrence = false;
    if (lower(peek()) == 'occurrence') {
      i++;
      occurrence = true;
    }
    final c = peek();
    if (c == null || c.type != TokenType.cmp) return KeywordNode(occurrence ? 'tracked occurrence' : 'tracked');
    i++;
    final v = peek();
    String message(int pos) => 'Expected a duration such as 30m or 1h30 after "${c.raw}" at position ${pos + 1}';
    if (v == null || v.type != TokenType.word) fail(message(c.pos), c.pos, ['duration']);
    final minutes = durationMinutes(v.value);
    if (minutes == null) fail(message(v.pos), v.pos, ['duration']);
    i++;
    return TrackedNode(c.op!, minutes, occurrence: occurrence);
  }

  /// `name cmp value` with the name already consumed; the comparison is next.
  FilterNode parseFieldTerm(String name, int pos) {
    final c = tokens[i++];
    return FieldNode(name, c.op!, parseFieldValue(c), pos, c.pos);
  }

  /// A quoted text, true or false, a date, a number, or any other bare word as text.
  FieldValueExpr parseFieldValue(Token after) {
    final tok = peek();
    if (tok?.type == TokenType.string) {
      i++;
      return TextValue(tok!.value);
    }
    if (tok == null || tok.type != TokenType.word) {
      fail('Expected a value after "${after.raw}" at position ${after.pos + 1}', after.pos, ['value']);
    }
    final w = tok.value.toLowerCase();
    if (w == 'true' || w == 'false') {
      i++;
      return BoolValue(w == 'true');
    }
    final unit = _digits.hasMatch(w) ? lower(at(i + 1)) : '';
    if (_dateStarts.contains(w) || weekdays.contains(w) || isoDateRe.hasMatch(w) || _dateUnits.contains(unit)) {
      return DateValue(parseDate(after));
    }
    i++;
    if (_numberRe.hasMatch(w)) return NumberValue(num.parse(w));
    return TextValue(tok.value);
  }

  DateExpr parseDate(Token after) {
    final tok = peek();
    if (tok == null || tok.type != TokenType.word) {
      fail('Expected a date after "${after.raw}" at position ${after.pos + 1}', after.pos, ['date']);
    }
    final w = tok.value.toLowerCase();
    i++;
    if (w == 'today') return const RelativeDate(0);
    if (w == 'tomorrow') return const RelativeDate(1);
    if (w == 'yesterday') return const RelativeDate(-1);
    final wd = weekdays.indexOf(w);
    if (wd >= 0) return WeekdayDate(wd);
    if (isoDateRe.hasMatch(w)) {
      if (!validIso(w)) fail('Invalid date "${tok.raw}" at position ${tok.pos + 1}', tok.pos, ['date']);
      return IsoDate(w);
    }
    if (w == 'this' || w == 'last' || w == 'next') {
      final unit = lower(peek());
      if (unit != 'week' && unit != 'month') {
        fail('Expected "week" or "month" after "${tok.raw}" at position ${tok.pos + 1}', tok.pos, ['"week"', '"month"']);
      }
      i++;
      return PeriodDate(unit, w == 'this' ? 0 : (w == 'last' ? -1 : 1));
    }
    if (_digits.hasMatch(w)) return parseCount(tok, int.tryParse(w) ?? 0x7fffffff);
    fail('Invalid date "${tok.raw}" at position ${tok.pos + 1}', tok.pos, ['date']);
  }

  /// `N days [ago]` or `N weeks|months ago`, with N consumed.
  DateExpr parseCount(Token tok, int n) {
    final unitTok = peek();
    final unit = lower(unitTok);
    if (unit == 'days') {
      i++;
      if (lower(peek()) == 'ago') {
        i++;
        return RelativeDate(-n);
      }
      return RelativeDate(n);
    }
    if (unit == 'week' || unit == 'weeks' || unit == 'month' || unit == 'months') {
      i++;
      if (lower(peek()) != 'ago') {
        fail('Expected "ago" after "${unitTok!.raw}" at position ${unitTok.pos + 1}', unitTok.pos, ['"ago"']);
      }
      i++;
      return PeriodDate(unit.startsWith('week') ? 'week' : 'month', n == 0 ? 0 : -n);
    }
    fail('Expected "days", "weeks" or "months" after "${tok.raw}" at position ${tok.pos + 1}', tok.pos, ['"days"', '"weeks"', '"months"']);
  }
}

// ---- dates ----

/// An inclusive range of floating dates.
class DateRange {
  const DateRange(this.start, this.end);
  final String start;
  final String end;
}

/// Resolve a date expression to the days it denotes, against the viewer's local
/// calendar date `today` and first day of the week (0 = Sunday).
DateRange resolveRange(DateExpr expr, String today, [int weekStart = 1]) {
  switch (expr) {
    case PeriodDate(unit: 'week', :final offset):
      final start = shiftIso(today, -((weekdayOfIso(today) - weekStart + 7) % 7) + 7 * offset);
      return DateRange(start, shiftIso(start, 6));
    case PeriodDate(:final offset):
      return DateRange(monthStartIso(today, offset), shiftIso(monthStartIso(today, offset + 1), -1));
    default:
      final d = resolveDate(expr, today, weekStart);
      return DateRange(d, d);
  }
}

/// Resolve a date expression against `today` (YYYY-MM-DD); a period resolves to its first day.
String resolveDate(DateExpr expr, String today, [int weekStart = 1]) => switch (expr) {
      IsoDate(:final date) => date,
      RelativeDate(:final days) => shiftIso(today, days),
      // Next occurrence, today included.
      WeekdayDate(:final day) => shiftIso(today, (day - weekdayOfIso(today) + 7) % 7),
      PeriodDate() => resolveRange(expr, today, weekStart).start,
    };

// ---- printing ----

String _escape(String s) => s.replaceAllMapped(RegExp(r'["\\]'), (m) => '\\${m[0]}');

String _quote(String name) => _break.hasMatch(name) || name.isEmpty ? '"${_escape(name)}"' : name;

String _quoteAlways(String s) => '"${_escape(s)}"';

/// A number as JavaScript's String(n) writes it (5, 2.5, -1).
String jsNumber(num v) {
  if (v is double && v == v.truncateToDouble() && v.abs() < 1e21) return v.toInt().toString();
  return v.toString();
}

/// A field term's value as query text (`client = today` compares with "today").
String fieldValueText(FieldValueExpr v) => switch (v) {
      TextValue(:final value) => value,
      DateValue(:final date) => printDate(date),
      NumberValue(:final value) => jsNumber(value),
      BoolValue(:final value) => '$value',
    };

String _printFieldValue(FieldValueExpr v) => v is TextValue ? _quoteAlways(v.value) : fieldValueText(v);

/// A date expression as query text.
String printDate(DateExpr d) {
  switch (d) {
    case IsoDate(:final date):
      return date;
    case WeekdayDate(:final day):
      return weekdays[day];
    case PeriodDate(:final unit, :final offset):
      if (offset == 0) return 'this $unit';
      if (offset == -1) return 'last $unit';
      if (offset == 1) return 'next $unit';
      return '${-offset} ${unit}s ago';
    case RelativeDate(:final days):
      if (days == 0) return 'today';
      if (days == 1) return 'tomorrow';
      if (days == -1) return 'yesterday';
      return days < 0 ? '${-days} days ago' : '$days days';
  }
}

/// Canonical text with every compound expression parenthesised; re-parses to the same AST.
String printQuery(FilterNode n) => switch (n) {
      OrNode(:final items) => '(${items.map(printQuery).join(' | ')})',
      AndNode(:final items) => '(${items.map(printQuery).join(' & ')})',
      NotNode(:final item) => '!${printQuery(item)}',
      LabelNode(:final name) => '@${_quote(name)}',
      ProjectNode(:final name, :final descendants) => '${descendants ? '##' : '#'}${_quote(name)}',
      PriorityNode(:final value) => 'p$value',
      DateNode(:final field, :final op, :final date) => '$field ${op.text} ${printDate(date)}',
      KeywordNode(:final keyword) => keyword,
      SearchNode(:final text) => 'search: ${_quote(text)}',
      NotesNode(:final text) => 'notes: ${_quote(text)}',
      OriginNode(:final value) => 'origin: ${_quote(value)}',
      AssignedNode(:final name) => 'assigned: ${_quote(name)}',
      EnergyNode(:final value) => 'energy: $value',
      SectorNode(:final value) =>
        'sector: ${value.contains('-W') || RegExp(r'^\d').hasMatch(value) ? value : value.replaceFirst('-', ' ')}',
      WorkspaceNode(:final name) => 'workspace: ${_quote(name)}',
      // Field names are always quoted: a bare one could collide with a reserved word.
      FieldNode(:final name, :final op, :final value) => '${_quoteAlways(name)} ${op.text} ${_printFieldValue(value)}',
      NoFieldNode(:final name) => 'no ${_quoteAlways(name)}',
      TrackedNode(:final op, :final minutes, :final occurrence) => 'tracked ${occurrence ? 'occurrence ' : ''}${op.text} $minutes',
    };
