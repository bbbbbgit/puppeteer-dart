import 'dart:async';
import 'package:logging/logging.dart';
import 'package:puppeteer/puppeteer.dart';
import 'package:test/test.dart';
import 'utils.dart';

main() {
  Logger.root.onRecord.listen(print);

  Server server;
  Browser browser;
  BrowserContext context;
  Page page;
  setUpAll(() async {
    server = await Server.create();
    browser = await puppeteer.launch();
    context = browser.defaultBrowserContext;
  });

  tearDownAll(() async {
    await browser.close();
    await server.close();
  });

  setUp(() async {
    page = await browser.newPage();
  });

  tearDown(() async {
    await page.close();
  });

  group('Target', () {
    test('Browser.targets should return all of the targets', () async {
      // The pages will be the testing page and the original newtab page
      var targets = browser.targets;
      expect(
          targets.where(
              (target) => target.type == 'page' && target.url == 'about:blank'),
          isNotEmpty);
      expect(targets.where((target) => target.type == 'browser'), isNotEmpty);
    });
    test('Browser.pages should return all of the pages', () async {
      // The pages will be the testing page
      var allPages = await context.pages;
      expect(allPages.length, equals(2));
      expect(allPages, contains(page));
      expect(allPages[0], isNot(equals(allPages[1])));
    });
    test('should contain browser target', () async {
      var targets = browser.targets;
      var browserTarget = targets.where((target) => target.type == 'browser');
      expect(browserTarget, isNotEmpty);
    });
    test('should be able to use the default page in the browser', () async {
      // The pages will be the testing page and the original newtab page
      var allPages = await browser.pages;
      var originalPage = allPages.firstWhere((p) => p != page);
      expect(await originalPage.evaluate("() => ['Hello', 'world'].join(' ')"),
          equals('Hello world'));
      expect(await originalPage.$('body'), isNotNull);
    });
    test('should report when a new page is created and closed', () async {
      var otherPage = await waitFutures(
          context
              .waitForTarget((target) =>
                  target.url == server.crossProcessPrefix + '/empty.html')
              .then((target) => target.page),
          [
            page.evaluate('url => window.open(url)',
                args: [server.crossProcessPrefix + '/empty.html']),
          ]);
      expect(otherPage.url, contains(server.crossProcessPrefix));
      expect(await otherPage.evaluate("() => ['Hello', 'world'].join(' ')"),
          equals('Hello world'));
      expect(await otherPage.$('body'), isNotNull);

      var allPages = await context.pages;
      expect(allPages, contains(page));
      expect(allPages, contains(otherPage));

      var closePagePromise =
          context.onTargetDestroyed.first.then((target) => target.page);
      await otherPage.close();
      expect(await closePagePromise, equals(otherPage));

      allPages = await Future.wait(
          context.targets.map((target) => target.page).where((p) => p != null));
      expect(allPages, contains(page));
      expect(allPages, isNot(contains(otherPage)));
    });
    test('should report when a service worker is created and destroyed',
        () async {
      await page.goto(server.emptyPage);
      var createdTarget = context.onTargetCreated.first;

      await page.goto(server.prefix + '/serviceworkers/empty/sw.html');

      expect((await createdTarget).type, equals('service_worker'));
      expect((await createdTarget).url,
          equals(server.prefix + '/serviceworkers/empty/sw.js'));

      var destroyedTarget = context.onTargetDestroyed.first;
      await page.evaluate(
          '() => window.registrationPromise.then(registration => registration.unregister())');
      expect(await destroyedTarget, equals(await createdTarget));
    },
        //TODO(xha): debug
        skip: true);
    test('should report when a target url changes', () async {
      await page.goto(server.emptyPage);
      var changedTarget = context.onTargetChanged.first;
      await page.goto(server.crossProcessPrefix + '/');
      expect(
          (await changedTarget).url, equals(server.crossProcessPrefix + '/'));

      changedTarget = context.onTargetChanged.first;
      await page.goto(server.emptyPage);
      expect((await changedTarget).url, equals(server.emptyPage));
    });
    test('should not report uninitialized pages', () async {
      var targetChanged = false;
      var listener =
          context.onTargetChanged.listen((_) => targetChanged = true);
      var targetPromise = context.onTargetCreated.first;
      var newPagePromise = context.newPage();
      var target = await targetPromise;
      expect(target.url, equals('about:blank'));

      var newPage = await newPagePromise;
      var targetPromise2 = context.onTargetCreated.first;
      var evaluatePromise =
          newPage.evaluate("() => window.open('about:blank')");
      var target2 = await targetPromise2;
      expect(target2.url, equals('about:blank'));
      await evaluatePromise;
      await newPage.close();
      expect(targetChanged, isFalse,
          reason: 'target should not be reported as changed');
      await listener.cancel();
    });
    test('should not crash while redirecting if original request was missed',
        () async {
      Completer<Response> serverResponse;
      server.setRoute('assets/one-style.css', (req) {
        serverResponse = Completer<Response>();
        return serverResponse.future;
      });

      var targetFuture = context
          .waitForTarget((target) => target.url.contains('one-style.html'));
      // Open a new page. Use window.open to connect to the page later.
      await Future.wait([
        page.evaluate('url => window.open(url)',
            args: [server.prefix + '/one-style.html']),
        server.waitForRequest('assets/one-style.css')
      ]);
      // Connect to the opened page.
      var target = await targetFuture;
      var newPage = await target.page;
      // Issue a redirect.
      serverResponse.complete(Response.found('/assets/injectedstyle.css'));
      // Wait for the new page to load.
      await newPage.onLoad.first;
      // Cleanup.
      await newPage.close();
    });
    test('should have an opener', () async {
      await page.goto(server.emptyPage);
      var createdTarget = await waitFutures(context.onTargetCreated.first,
          [page.goto(server.prefix + '/popup/window-open.html')]);
      expect((await createdTarget.page).url,
          equals(server.prefix + '/popup/popup.html'));
      expect(createdTarget.opener, equals(page.target));
      expect(page.target.opener, equals(null));
    });
  }, timeout: Timeout(Duration(seconds: 10)));

  group('Browser.waitForTarget', () {
    test('should wait for a target', () async {
      var resolved = false;
      var targetPromise =
          browser.waitForTarget((target) => target.url == server.emptyPage);
      // ignore: unawaited_futures
      targetPromise.then((_) => resolved = true);
      var page = await browser.newPage();
      expect(resolved, isFalse);
      await page.goto(server.emptyPage);
      var target = await targetPromise;
      expect(await target.page, equals(page));
      await page.close();
    });
    test('should timeout waiting for a non-existent target', () async {
      expect(
          () => browser.waitForTarget(
              (target) => target.url == server.emptyPage,
              timeout: Duration(milliseconds: 1)),
          throwsA(TypeMatcher<TimeoutException>()));
    });
  });
}
