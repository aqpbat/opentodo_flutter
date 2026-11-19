// The filter parser against the server's reference cases
// (internal/filter/filter_test.go), the docs error table (docs/filters.md
// "Errors"), the shared limits (test/vectors/filter/limits.json) and the
// builder's formatted queries (test/vectors/filter/formatted.txt), all copied
// unchanged from upstream.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opentodo_flutter/domain/filter.dart';

String? errorOf(String q) {
  try {
    parseFilter(q);
    return null;
  } on FilterSyntaxError catch (e) {
    expect(e.position, e.offset + 1);
    return e.message;
  }
}

void main() {
  test('accepts the grammar examples and edge forms', () {
    const queries = [
      '@work & due <= tomorrow & p1', '@errand | @call & p1', '(@errand | @call) & p1', 'due<=tomorrow', //
      '#"Client A"', '@"follow up"', 'p1 & completed', 'completed | open', 'due = today', 'due <= today',
      '', '   ', '!!p1', '##Work & !(#Home | no project)', 'search:milk', 'search: "oat milk"', 'SEARCH: x',
      'created > 7 days ago', 'due before monday', 'due after 2026-02-28', 'P2', r'@"a \"quoted\" name"',
      'no date | no time | no labels', '@Café & #プロジェクト',
      'deadline <= 3 days', '#Work & no deadline', 'deadline >= today & no date', 'deadline before friday',
      '@waiting & !someday', 'deferred & start <= 6 days', '#Home & evening', '#Home & morning', 'today & afternoon',
      'no start', 'start after 2026-10-20',
      'completed = last week', 'completed >= this month & p1', 'completed before yesterday', 'due = next week',
      'created = 2 months ago', 'deadline < 1 week ago', 'start <= next month', '!(completed > 3 weeks ago) | open',
      'completed', 'p1 & completed', 'COMPLETED AFTER 2026-10-01',
      'cost > 100', 'client = "Acme"', '"Order date" <= friday & cost > 100', 'no cost', 'no "Order date"', 'done = true',
      'origin', 'no origin', 'origin: github', 'origin:github', 'origin: "my tracker"', 'origin: url | origin: email',
      'no origin & #Work', 'origin: github & open', '!origin',
      'energy', 'no energy', 'energy: deep', 'energy:LOW', 'energy: "medium"', 'energy: low & unblocked & today',
      'energy: deep & #Work', '"energy" = 3',
      'sector', 'no sector', 'carried', 'sector: this week', 'sector:next-month', 'sector: "this quarter"',
      'SECTOR: Next Quarter', 'sector: 2026-W44', 'sector:2026-11', 'sector: 2026-q4', '#Work & sector: this week',
      'carried | sector: this week', '!sector & open',
      'notes', 'no notes', 'notes: permit', 'notes:permit', 'notes: "permit office"', 'NOTES: x', 'notes & #Renovation',
      'no notes & p1', '!notes', '"Notes" = 3', 'no "Notes"', 'notes: "a & b"',
      'assigned', 'unassigned', '!assigned', 'assigned: me', 'assigned:me', 'assigned: "Sam Lee"', 'ASSIGNED: sam',
      'today & (assigned: me | unassigned)', '"assigned" = x',
      'workspace: Home', 'workspace:Home', 'workspace:"Side projects"', 'workspace: "Side projects" & p1',
      'WORKSPACE: work', '(workspace: Home | workspace: Work) & due = this week', '!workspace: Home',
      'workspace: home & no project',
      'paid = false', 'cost >= -2.5', 'status = Ordered', 'due_by <= 3 days', '"due" = 2026-10-16', 'no idea',
      'kitchen = this week',
    ];
    for (final q in queries) {
      expect(errorOf(q), isNull, reason: q);
    }
  });

  test('matches the docs error table', () {
    const table = {
      '@errand &': 'Expected a term after "&" at position 9',
      '(p1 | p2': 'Missing ")" at end of query',
      '@work p1': 'Expected "&" or "|" before "p1" at position 7',
      'p1 & urgent': 'Unknown term "urgent" at position 6',
      'p5': 'Priority must be p1, p2, p3 or p4 at position 1',
      'due today': 'Expected a comparison (<, <=, =, >=, >, before or after) after "due" at position 1',
      'due > 7': 'Expected "days", "weeks" or "months" after "7" at position 7',
      'due = last year': 'Expected "week" or "month" after "last" at position 7',
      'completed > 2 weeks': 'Expected "ago" after "weeks" at position 15',
      'no &': 'Expected "date", "project", "labels", "time", "deadline", "start", "origin" or a field name after "no" at position 1',
      'cost >': 'Expected a value after ">" at position 6',
      'tracked > soon': 'Expected a duration such as 30m or 1h30 after ">" at position 11',
      'workspace: & p1': 'Expected a workspace name after "workspace:" at position 1',
      'energy: high': 'Energy must be deep, medium or low at position 1',
      'sector: 2026-W60':
          'Unknown time sector "2026-W60" at position 1; use this week, next week, this month, next month, this quarter, next quarter or a period such as 2026-W44',
      'notes: & p1': 'Expected text after "notes:" at position 1',
    };
    table.forEach((q, want) => expect(errorOf(q), want, reason: q));
  });

  test('rejects with the server messages', () {
    const sectorHint = 'use this week, next week, this month, next month, this quarter, next quarter or a period such as 2026-W44';
    const cases = {
      '@': 'Expected a label name after "@" at position 1',
      '# & p1': 'Expected a project name after "#" at position 1',
      '@"open': 'Missing closing quote for the text starting at position 2',
      'search:': 'Expected text after "search:" at position 1',
      'origin:': 'Expected a provider or kind after "origin:" at position 1',
      'workspace:': 'Expected a workspace name after "workspace:" at position 1',
      'p1 & workspace: ': 'Expected a workspace name after "workspace:" at position 6',
      'workspace: "Home': 'Missing closing quote for the text starting at position 12',
      'origin: & p1': 'Expected a provider or kind after "origin:" at position 1',
      'origin = x': 'Expected "&" or "|" before "=" at position 8',
      'energy: high': 'Energy must be deep, medium or low at position 1',
      'p1 & energy:': 'Energy must be deep, medium or low at position 6',
      'energy = deep': 'Expected "&" or "|" before "=" at position 8',
      'sector: 2026-W60': 'Unknown time sector "2026-W60" at position 1; $sectorHint',
      'p1 & sector: soon': 'Unknown time sector "soon" at position 6; $sectorHint',
      'sector: this year': 'Unknown time sector "this year" at position 1; $sectorHint',
      'assigned:': 'Expected a name after "assigned:" at position 1',
      'p1 & assigned: ': 'Expected a name after "assigned:" at position 6',
      'notes:': 'Expected text after "notes:" at position 1',
      'p1 & notes: ': 'Expected text after "notes:" at position 6',
      'notes: & p1': 'Expected text after "notes:" at position 1',
      'notes: "permit': 'Missing closing quote for the text starting at position 8',
      'notes = 3': 'Expected "&" or "|" before "=" at position 7',
      'p1 )': 'Unexpected ")" at position 4',
      '(p1 p2)': 'Expected "&", "|" or ")" before "p2" at position 5',
      '!': 'Expected a term after "!" at position 1',
      '()': 'Expected a term after "(" at position 1',
      '"loose text"': 'Unexpected text "loose text" at position 1; quote names after "@" or "#", or use search:',
      'no': 'Expected "date", "project", "labels", "time", "deadline", "start", "origin" or a field name after "no" at position 1',
      'no & p1': 'Expected "date", "project", "labels", "time", "deadline", "start", "origin" or a field name after "no" at position 1',
      'cost >': 'Expected a value after ">" at position 6',
      'cost = last year': 'Expected "week" or "month" after "last" at position 8',
      'cost 5': 'Unknown term "cost" at position 1',
      'due < someday': 'Invalid date "someday" at position 7',
      'due < 2026-02-30': 'Invalid date "2026-02-30" at position 7',
      'due <': 'Expected a date after "<" at position 5',
      'created = 3 weeks': 'Expected "ago" after "weeks" at position 13',
      'created = 3 years': 'Expected "days", "weeks" or "months" after "3" at position 11',
      'due = this year': 'Expected "week" or "month" after "this" at position 7',
      'due = next': 'Expected "week" or "month" after "next" at position 7',
      'completed after': 'Expected a date after "after" at position 11',
      'completed today': 'Expected "&" or "|" before "today" at position 11',
      'p0': 'Priority must be p1, p2, p3 or p4 at position 1',
      '@work & colour': 'Unknown term "colour" at position 9',
      'p1 & & p2': 'Expected a term after "&" at position 4',
      'due = today today ': 'Expected "&" or "|" before "today" at position 13',
    };
    cases.forEach((q, want) => expect(errorOf(q), want, reason: q));
  });

  test('tracked terms', () {
    for (final q in [
      'tracked', '!tracked & #Work', 'tracked > 1h', 'tracked <= 1h', 'tracked >= 1h30', 'tracked < 1.5h', //
      'tracked = 0', 'tracked > 45min', 'tracked > 90', 'TRACKED > 30M', 'tracked > 10', '"tracked" > 10',
      'tracked & due <= today', 'tracked occurrence', '!tracked occurrence & p1', 'tracked occurrence > 1h',
      'Tracked Occurrence <= 30m',
    ]) {
      expect(errorOf(q), isNull, reason: q);
    }
    const bad = {
      'tracked > soon': 'Expected a duration such as 30m or 1h30 after ">" at position 11',
      'tracked >': 'Expected a duration such as 30m or 1h30 after ">" at position 9',
      'tracked = 1h75': 'Expected a duration such as 30m or 1h30 after "=" at position 11',
      'tracked > +30m': 'Expected a duration such as 30m or 1h30 after ">" at position 11',
      'tracked today': 'Expected "&" or "|" before "today" at position 9',
      'tracked occurrence >': 'Expected a duration such as 30m or 1h30 after ">" at position 20',
    };
    bad.forEach((q, want) => expect(errorOf(q), want, reason: q));
    final n = parseFilter('tracked >= 1h30') as TrackedNode;
    expect((n.op, n.minutes), (Cmp.ge, 90));
  });

  test('limits.json', () {
    final doc = jsonDecode(File('test/vectors/filter/limits.json').readAsStringSync()) as Map<String, dynamic>;
    expect(doc['maxQueryLength'], maxQueryLength);
    expect(doc['maxNesting'], maxNesting);
    for (final v in (doc['vectors'] as List).cast<Map<String, dynamic>>()) {
      final q = '${v['prefix']}${(v['repeat'] as String) * (v['times'] as int)}${v['suffix']}'
          '${(v['close'] as String) * (v['closeTimes'] as int)}';
      expect(errorOf(q), v['error'], reason: q.length > 40 ? '${q.substring(0, 40)}…' : q);
    }
  });

  test('formatted.txt: every builder query parses and prints back stably', () {
    final lines = File('test/vectors/filter/formatted.txt')
        .readAsLinesSync()
        .where((l) => l.isNotEmpty && !l.startsWith('# '))
        .toList();
    expect(lines.length, greaterThanOrEqualTo(150));
    for (final q in lines) {
      expect(errorOf(q), isNull, reason: q);
      final printed = printQuery(parseFilter(q)!);
      expect(printQuery(parseFilter(printed)!), printed, reason: q);
    }
  });

  test('AST shapes and precedence', () {
    final n = parseFilter('@errand | @call & p1') as OrNode;
    expect(n.items[0], isA<LabelNode>());
    expect(n.items[1], isA<AndNode>());
    expect(printQuery(n), '(@errand | (@call & p1))');
    expect(printQuery(parseFilter('##Work & !(#Home | no project)')!), '(##Work & !(#Home | no project))');
    expect(printQuery(parseFilter('#"Client A" & @"say \\"hi\\""')!), r'(#"Client A" & @"say \"hi\"")');
    expect(printQuery(parseFilter('cost >= -2.5 & "Order date" <= friday & client = Acme')!),
        '("cost" >= -2.5 & "Order date" <= friday & "client" = "Acme")');
    expect(printQuery(parseFilter('completed > 3 weeks ago')!), 'completed > 3 weeks ago');
    expect(printQuery(parseFilter('due before monday')!), 'due < monday');
    expect(printQuery(parseFilter('SECTOR: Next Quarter')!), 'sector: next quarter');
    expect(printQuery(parseFilter('sector: 2026-q4')!), 'sector: 2026-Q4');
    expect(parseFilter('   '), isNull);
  });

  test('resolveRange and resolveDate', () {
    // 2026-11-04 is a Wednesday.
    const today = '2026-11-04';
    DateRange r(String q) => resolveRange((parseFilter('due = $q') as DateNode).date, today);
    expect((r('this week').start, r('this week').end), ('2026-11-02', '2026-11-08'));
    expect(r('last week').start, '2026-10-26');
    expect((r('next month').start, r('next month').end), ('2026-12-01', '2026-12-31'));
    expect((r('2 months ago').start, r('2 months ago').end), ('2026-09-01', '2026-09-30'));
    expect(r('friday').start, '2026-11-06');
    expect(r('wednesday').start, today);
    expect(r('3 days ago').start, '2026-11-01');
    expect(resolveRange(const PeriodDate('week', 0), today, 0).start, '2026-11-01');
  });
}
