import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/personal_library.dart';
import 'package:yingyu/playback/skip_policy.dart';
import 'core_test.dart' show syntheticSession;
import 'personal_features_test.dart' show featureEpisode, featureMovie;

const duration = Duration(minutes: 10);
const intro = IntroRange(Duration(seconds: 10), Duration(seconds: 90));
const manualRule = SkipRule(
  intro: intro,
  creditsRemaining: Duration(seconds: 60),
);
const automaticRule = SkipRule(
  intro: intro,
  creditsRemaining: Duration(seconds: 60),
  autoIntro: true,
  autoCredits: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late PersonalLibrary library;
  final account = syntheticSession();
  final episode = featureEpisode('1');
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    library = PersonalLibrary(prefs);
  });
  tearDown(() => library.dispose());

  test('automatic prompt counts three allowed seconds exactly once', () {
    final prompt = SkipCountdown(
      const SkipTarget(SkipPart.intro, Duration(seconds: 90)),
    );
    expect(prompt.remaining, 3);
    expect(prompt.tick(allowed: false), isFalse);
    expect(prompt.remaining, 3);
    expect(prompt.tick(allowed: true), isFalse);
    expect(prompt.remaining, 2);
    expect(prompt.tick(allowed: false), isFalse);
    expect(prompt.remaining, 2);
    expect(prompt.tick(allowed: true), isFalse);
    expect(prompt.tick(allowed: true), isTrue);
    expect(prompt.tick(allowed: true), isFalse);
  });

  test(
    'legacy season bytes remain readable, manual and more specific than series',
    () async {
      final legacy = jsonEncode({
        'intros': {
          PersonalLibrary.introScope(episode)!: {'start': 10000, 'end': 90000},
        },
      });
      await prefs.setString(library.storageKey(account), legacy);
      final saved = library.resolveSkipRule(account, featureEpisode('2'))!;
      expect(saved.legacy, isTrue);
      expect(saved.scope, SkipScope.season);
      expect(saved.rule.intro!.end.inSeconds, 90);
      expect(saved.rule.autoIntro, isFalse);
      expect(prefs.getString(library.storageKey(account)), legacy);
      await library.setSkipRule(
        account,
        episode,
        SkipScope.series,
        const SkipRule(creditsRemaining: Duration(seconds: 30)),
        duration,
      );
      expect(
        library.resolveSkipRule(account, episode)!.scope,
        SkipScope.season,
      );
      expect(library.intro(account, episode)!.end.inSeconds, 90);
    },
  );

  test(
    'specific scope wins; disable and remove restore broader rules durably',
    () async {
      for (final scope in SkipScope.values.reversed) {
        await library.setSkipRule(
          account,
          episode,
          scope,
          manualRule,
          duration,
        );
        expect(library.resolveSkipRule(account, episode)!.scope, scope);
      }
      await library.setSkipRule(
        account,
        episode,
        SkipScope.item,
        const SkipRule(enabled: false),
        duration,
      );
      final reload = PersonalLibrary(prefs);
      expect(reload.resolveSkipRule(account, episode)!.rule.enabled, isFalse);
      reload.dispose();
      await library.setSkipRule(
        account,
        episode,
        SkipScope.item,
        null,
        Duration.zero,
      );
      expect(
        PersonalLibrary(prefs).resolveSkipRule(account, episode)!.scope,
        SkipScope.season,
      );
      await library.setSkipRule(
        account,
        episode,
        SkipScope.season,
        null,
        duration,
      );
      expect(
        PersonalLibrary(prefs).resolveSkipRule(account, episode)!.scope,
        SkipScope.series,
      );
      await library.setSkipRule(
        account,
        episode,
        SkipScope.series,
        null,
        duration,
      );
      expect(PersonalLibrary(prefs).resolveSkipRule(account, episode), isNull);
    },
  );

  test(
    'scopes use concrete IDs and remain isolated by user server and version',
    () async {
      await library.setSkipRule(
        account,
        episode,
        SkipScope.season,
        automaticRule,
        duration,
      );
      expect(
        library.resolveSkipRule(account, featureEpisode('2'))!.rule.autoIntro,
        isTrue,
      );
      expect(
        library.resolveSkipRule(account, featureEpisode('2', season: 's2')),
        isNull,
      );
      expect(
        library.resolveSkipRule(
          account,
          featureEpisode('2', series: 'different'),
        ),
        isNull,
      );
      final otherUser = Session(
        base: account.base,
        userId: 'other',
        token: 'x',
        username: 'other',
        deviceId: 'synthetic',
      );
      expect(library.resolveSkipRule(otherUser, episode), isNull);
      expect(
        library.resolveSkipRule(
          syntheticSession('https://another.invalid/emby'),
          episode,
        ),
        isNull,
      );
      final sparse = MediaItem({
        'Id': '2',
        'Type': 'Episode',
        'SeriesId': 'series',
        'ParentIndexNumber': 1,
      });
      expect(
        PersonalLibrary.skipScopeKey(sparse, SkipScope.season),
        contains('number:1'),
      );
      final missingSeason = MediaItem({
        'Id': '2',
        'Type': 'Episode',
        'SeriesId': 'series',
      });
      expect(
        PersonalLibrary.skipScopeKey(missingSeason, SkipScope.season),
        isNull,
      );
      await expectLater(
        library.setSkipRule(
          account,
          missingSeason,
          SkipScope.season,
          manualRule,
          duration,
        ),
        throwsA(isA<AppFailure>()),
      );
      final movie = featureMovie('movie');
      expect(PersonalLibrary.skipScopeKey(movie, SkipScope.season), isNull);
      expect(PersonalLibrary.skipScopeKey(movie, SkipScope.series), isNull);
      await library.setSkipRule(
        account,
        movie,
        SkipScope.item,
        manualRule,
        duration,
      );
      expect(
        library.resolveSkipRule(account, featureMovie('movie'))!.scope,
        SkipScope.item,
      );
      expect(
        library.resolveSkipRule(account, featureMovie('other-version')),
        isNull,
      );
    },
  );

  test(
    'legacy season number fallback remains editable, durable and removable',
    () async {
      final sparse = MediaItem({
        'Id': '1',
        'Type': 'Episode',
        'SeriesId': 'server-series',
        'ParentIndexNumber': 0,
      });
      final sibling = MediaItem({...sparse.data, 'Id': '2'});
      await library.setIntro(account, sparse, intro, duration);
      final old = library.resolveSkipRule(account, sibling)!;
      expect(old.legacy, isTrue);
      expect(old.scope, SkipScope.season);
      await library.setSkipRule(
        account,
        sparse,
        SkipScope.season,
        automaticRule,
        duration,
      );
      final reload = PersonalLibrary(prefs);
      expect(
        reload.resolveSkipRule(account, sibling)!.rule.toJson(),
        automaticRule.toJson(),
      );
      expect(reload.intro(account, sibling)!.end.inSeconds, 90);
      expect(
        reload.resolveSkipRule(
          account,
          MediaItem({...sibling.data, 'ParentIndexNumber': 1}),
        ),
        isNull,
      );
      expect(
        reload.resolveSkipRule(
          account,
          MediaItem({...sibling.data, 'SeriesId': 'other-series'}),
        ),
        isNull,
      );
      reload.dispose();
      await library.setSkipRule(
        account,
        sparse,
        SkipScope.season,
        null,
        duration,
      );
      expect(PersonalLibrary(prefs).resolveSkipRule(account, sibling), isNull);
      for (final invalid in [-1, 'unknown', 1.5, null]) {
        expect(
          PersonalLibrary.skipScopeKey(
            MediaItem({...sparse.data, 'ParentIndexNumber': invalid}),
            SkipScope.season,
          ),
          isNull,
        );
      }
    },
  );

  test(
    'credits are relative to the real duration with precise range boundaries',
    () {
      expect(
        manualRule.creditsContains(const Duration(seconds: 539), duration),
        isFalse,
      );
      expect(
        manualRule.creditsContains(const Duration(seconds: 540), duration),
        isTrue,
      );
      expect(manualRule.creditsContains(duration, duration), isFalse);
      expect(
        manualRule.creditsContains(
          const Duration(seconds: 640),
          const Duration(seconds: 700),
        ),
        isTrue,
      );
      expect(
        manualRule.introContains(const Duration(seconds: 10), duration),
        isTrue,
      );
      expect(
        manualRule.introContains(const Duration(seconds: 90), duration),
        isFalse,
      );
      expect(manualRule.autoIntro, isFalse);
      expect(manualRule.autoCredits, isFalse);
    },
  );

  for (final (name, rule, length) in <(String, SkipRule, Duration)>[
    ('no ranges', const SkipRule(), duration),
    ('unknown duration', manualRule, Duration.zero),
    (
      'negative intro',
      const SkipRule(
        intro: IntroRange(Duration(seconds: -1), Duration(seconds: 20)),
      ),
      duration,
    ),
    (
      'reversed intro',
      const SkipRule(
        intro: IntroRange(Duration(seconds: 90), Duration(seconds: 10)),
      ),
      duration,
    ),
    (
      'intro reaches end',
      const SkipRule(intro: IntroRange(Duration.zero, duration)),
      duration,
    ),
    ('zero credits', const SkipRule(creditsRemaining: Duration.zero), duration),
    (
      'negative credits',
      const SkipRule(creditsRemaining: Duration(seconds: -1)),
      duration,
    ),
    (
      'credits cover whole item',
      const SkipRule(creditsRemaining: duration),
      duration,
    ),
    (
      'overlap',
      const SkipRule(intro: intro, creditsRemaining: Duration(seconds: 511)),
      duration,
    ),
  ]) {
    test(
      'invalid $name is rejected without replacing the saved rule',
      () async {
        await library.setSkipRule(
          account,
          episode,
          SkipScope.item,
          manualRule,
          duration,
        );
        final before = prefs.getString(library.storageKey(account));
        await expectLater(
          library.setSkipRule(account, episode, SkipScope.item, rule, length),
          throwsA(isA<AppFailure>()),
        );
        expect(prefs.getString(library.storageKey(account)), before);
        expect(
          library.resolveSkipRule(account, episode)!.rule.toJson(),
          manualRule.toJson(),
        );
      },
    );
  }

  test(
    'adjacent ranges are valid; shorter episodes never activate overlapping rule',
    () async {
      const adjacent = SkipRule(
        intro: intro,
        creditsRemaining: Duration(seconds: 510),
      );
      expect(adjacent.validFor(duration), isTrue);
      expect(adjacent.validFor(const Duration(seconds: 550)), isFalse);
      expect(
        adjacent.introContains(
          const Duration(seconds: 20),
          const Duration(seconds: 550),
        ),
        isFalse,
      );
      expect(
        adjacent.creditsContains(
          const Duration(seconds: 540),
          const Duration(seconds: 550),
        ),
        isFalse,
      );
    },
  );

  test(
    'replacing or deleting legacy season does not resurrect old intro',
    () async {
      await library.setIntro(account, episode, intro, duration);
      await library.setSkipRule(
        account,
        episode,
        SkipScope.season,
        const SkipRule(creditsRemaining: Duration(seconds: 30)),
        duration,
      );
      expect(library.intro(account, episode), isNull);
      await library.setSkipRule(
        account,
        episode,
        SkipScope.season,
        null,
        duration,
      );
      expect(PersonalLibrary(prefs).resolveSkipRule(account, episode), isNull);
    },
  );

  test(
    'legacy API edits only season intro and retains new credits and automation',
    () async {
      await library.setSkipRule(
        account,
        episode,
        SkipScope.season,
        automaticRule,
        duration,
      );
      const replacement = IntroRange(Duration.zero, Duration(seconds: 50));
      await library.setIntro(account, episode, replacement, duration);
      final saved = library.resolveSkipRule(account, episode)!.rule;
      expect(saved.intro!.end.inSeconds, 50);
      expect(saved.creditsRemaining!.inSeconds, 60);
      expect(saved.autoIntro, isTrue);
      expect(saved.autoCredits, isTrue);
      await library.setIntro(account, episode, null, duration);
      expect(library.intro(account, episode), isNull);
      expect(
        library
            .resolveSkipRule(account, episode)!
            .rule
            .creditsRemaining!
            .inSeconds,
        60,
      );
    },
  );

  test(
    'concurrent scope writes and removals retain unrelated personal data',
    () async {
      await library.setSaved(
        account,
        SavedList.watchlist,
        featureMovie('movie'),
        true,
      );
      await Future.wait([
        for (final scope in SkipScope.values)
          library.setSkipRule(account, episode, scope, manualRule, duration),
      ]);
      for (final scope in SkipScope.values) {
        expect(
          PersonalLibrary(
            prefs,
          ).skipRuleAt(account, episode, scope)!.rule.toJson(),
          manualRule.toJson(),
        );
      }
      expect(
        PersonalLibrary(prefs).contains(account, SavedList.watchlist, 'movie'),
        isTrue,
      );
    },
  );

  test(
    'corrupt narrow rule is reported without falling back to automatic series',
    () async {
      await library.setSkipRule(
        account,
        episode,
        SkipScope.series,
        automaticRule,
        duration,
      );
      final data = object(
        jsonDecode(prefs.getString(library.storageKey(account))!),
      );
      data['skipRules'] = {
        ...object(data['skipRules']),
        PersonalLibrary.skipScopeKey(episode, SkipScope.item)!: {
          'enabled': true,
          'autoIntro': 'yes',
        },
      };
      await prefs.setString(library.storageKey(account), jsonEncode(data));
      final reload = PersonalLibrary(prefs);
      expect(
        () => reload.resolveSkipRule(account, episode),
        throwsA(isA<AppFailure>()),
      );
      expect(prefs.getString(library.storageKey(account)), jsonEncode(data));
      reload.dispose();
    },
  );

  test(
    'automatic policy attempts each part once and never rearms on return',
    () {
      final policy = SkipPolicy();
      SkipTarget? at(
        int seconds, {
        bool allowed = true,
        bool seeking = false,
      }) => policy.automatic(
        rule: automaticRule,
        position: Duration(seconds: seconds),
        duration: duration,
        allowed: allowed,
        seeking: seeking,
      );
      expect(at(9), isNull);
      expect(at(10)!.position.inSeconds, 90);
      expect(at(20), isNull);
      expect(at(540)!.position, duration);
      expect(at(550), isNull);
      expect(at(20), isNull);
      expect(at(540), isNull);
      expect(
        SkipPolicy().automatic(
          rule: automaticRule,
          position: const Duration(seconds: 20),
          duration: duration,
          allowed: true,
          seeking: false,
        ),
        isNotNull,
      );
    },
  );

  test(
    'saving or pending manual seek inside a range suppresses automatic action',
    () {
      for (final saving in [false, true]) {
        final policy = SkipPolicy();
        if (saving) {
          policy.suppressCurrent(
            automaticRule,
            const Duration(seconds: 20),
            duration,
          );
        } else {
          policy.automatic(
            rule: automaticRule,
            position: const Duration(seconds: 20),
            duration: duration,
            allowed: false,
            seeking: true,
          );
        }
        expect(
          policy.automatic(
            rule: automaticRule,
            position: const Duration(seconds: 21),
            duration: duration,
            allowed: true,
            seeking: false,
          ),
          isNull,
        );
        expect(
          policy
              .automatic(
                rule: automaticRule,
                position: const Duration(seconds: 540),
                duration: duration,
                allowed: true,
                seeking: false,
              )!
              .part,
          SkipPart.credits,
        );
      }
    },
  );

  test(
    'manual rules, disabled rules and blocked playback never seek automatically',
    () {
      final policy = SkipPolicy();
      for (final rule in [
        manualRule,
        const SkipRule(enabled: false, intro: intro, autoIntro: true),
        null,
      ]) {
        expect(
          policy.automatic(
            rule: rule,
            position: const Duration(seconds: 20),
            duration: duration,
            allowed: true,
            seeking: false,
          ),
          isNull,
        );
      }
      expect(
        policy.automatic(
          rule: automaticRule,
          position: const Duration(seconds: 20),
          duration: duration,
          allowed: false,
          seeking: false,
        ),
        isNull,
      );
      expect(
        policy.automatic(
          rule: automaticRule,
          position: const Duration(seconds: 20),
          duration: duration,
          allowed: true,
          seeking: false,
        ),
        isNotNull,
      );
    },
  );
}
