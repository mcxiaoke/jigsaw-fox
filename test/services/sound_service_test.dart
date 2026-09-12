import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/services/sound_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SoundService Unit Tests', () {
    test('singleton instance is non-null and accessible via I getter', () {
      expect(SoundService.instance, isNotNull);
      expect(SoundService.I, same(SoundService.instance));
    });

    test(
      'all Sfx enum values can be queried and play safely in test environment',
      () {
        for (final sfx in Sfx.values) {
          expect(() => SoundService.I.play(sfx), returnsNormally);
        }
      },
    );

    test(
      'convenience methods playSnap, playTap, playSwitchToggle run safely',
      () {
        expect(() => SoundService.I.playSnap(), returnsNormally);
        expect(() => SoundService.I.playTap(), returnsNormally);
        expect(() => SoundService.I.playSwitchToggle(), returnsNormally);
      },
    );

    test('stopAll executes cleanly without throwing', () {
      expect(() => SoundService.I.stopAll(), returnsNormally);
    });

    test('allAssets list contains 27 valid wav assets', () {
      expect(SoundService.allAssets.length, 27);
      for (final asset in SoundService.allAssets) {
        expect(asset.endsWith('.wav'), isTrue);
      }
    });

    test('calibrated durations match real asset lengths', () {
      expect(
        SoundService.I.durationFor(Sfx.numbers),
        const Duration(milliseconds: 100),
      );
      expect(
        SoundService.I.durationFor(Sfx.place),
        const Duration(milliseconds: 150),
      );
      expect(
        SoundService.I.durationFor(Sfx.snap),
        const Duration(milliseconds: 200),
      );
      expect(
        SoundService.I.durationFor(Sfx.switchToggle),
        const Duration(milliseconds: 200),
      );
      // win.wav 实盘 78.9KB @32kHz 单声道 16bit (~1.233s)，断言至少 1500ms 防止尾音被掐断
      expect(
        SoundService.I.durationFor(Sfx.win),
        const Duration(milliseconds: 1500),
      );
      expect(
        SoundService.I.durationFor(Sfx.win).inMilliseconds,
        greaterThan(1200),
      );
      expect(
        SoundService.I.durationFor(Sfx.winBig),
        const Duration(milliseconds: 5000),
      );
    });

    test('isolated throttle table prevents audio storms', () {
      expect(SoundService.I.throttleMsFor(Sfx.snap), 80);
      expect(SoundService.I.throttleMsFor(Sfx.place), 60);
      expect(SoundService.I.throttleMsFor(Sfx.tap), 70);
      expect(SoundService.I.throttleMsFor(Sfx.coinsFly), 200);
      expect(SoundService.I.throttleMsFor(Sfx.hint), 300);
      expect(SoundService.I.throttleMsFor(Sfx.win), 1000);
    });

    test(
      'generation increments on stopAll and dispose to cancel pending plays',
      () {
        final initialGen = SoundService.I.generation;
        SoundService.I.stopAll();
        expect(SoundService.I.generation, initialGen + 1);
        SoundService.I.stopAll();
        expect(SoundService.I.generation, initialGen + 2);
      },
    );

    test('selectSlotForPlay prioritizes free idle slot', () {
      SoundService.I.setupMockPool(3);
      final pool = SoundService.I.testPool;
      expect(pool.length, 3);
      expect(pool.every((s) => !s.isBusy), isTrue);

      final slot = SoundService.I.selectSlotForPlay('place.wav');
      expect(slot, isNotNull);
      expect(slot!.id, 0);
    });

    test(
      'selectSlotForPlay preempts oldest non-victory slot when pool is full',
      () {
        SoundService.I.setupMockPool(3);
        final pool = SoundService.I.testPool;

        // slot 0: 最老普通音效 (playedAt = 200)
        pool[0].isBusy = true;
        pool[0].currentFile = 'snap.wav';
        pool[0].playedAtMs = 200;

        // slot 1: 更早的胜利音效 (playedAt = 100) -> 应当受保护不被首先抢占
        pool[1].isBusy = true;
        pool[1].currentFile = 'win.wav';
        pool[1].playedAtMs = 100;

        // slot 2: 较新的普通音效 (playedAt = 300)
        pool[2].isBusy = true;
        pool[2].currentFile = 'tap.wav';
        pool[2].playedAtMs = 300;

        // 请求新声音，应抢占最老的非胜利槽位 slot 0，而不是更老的胜利槽位 slot 1
        final chosen = SoundService.I.selectSlotForPlay('hint.wav');
        expect(chosen, isNotNull);
        expect(chosen!.id, 0);
      },
    );

    test(
      'selectSlotForPlay falls back to oldest victory slot only when all slots are victory',
      () {
        SoundService.I.setupMockPool(2);
        final pool = SoundService.I.testPool;

        pool[0].isBusy = true;
        pool[0].currentFile = 'win.wav';
        pool[0].playedAtMs = 150;

        pool[1].isBusy = true;
        pool[1].currentFile = 'TrophySound.wav';
        pool[1].playedAtMs = 100;

        // 全是胜利音效，兜底抢占时间最早的 slot 1
        final chosen = SoundService.I.selectSlotForPlay('tap.wav');
        expect(chosen, isNotNull);
        expect(chosen!.id, 1);
      },
    );

    test('SoundSlot resetSync clears state and increments playToken', () {
      final slot = SoundSlot(0);
      slot
        ..isBusy = true
        ..currentFile = 'win.wav';
      final initialToken = slot.playToken;

      slot.resetSync();

      expect(slot.isBusy, isFalse);
      expect(slot.currentFile, isNull);
      expect(slot.playToken, initialToken + 1);
    });
  });
}
