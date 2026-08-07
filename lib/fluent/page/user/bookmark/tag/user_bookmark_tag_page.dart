import 'package:easy_refresh/easy_refresh.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:pixez/component/pixez_default_header.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/main.dart';
import 'package:pixez/page/user/bookmark/tag/bookmark_tag_store.dart';

class UserBookmarkTagPage extends StatefulWidget {
  @override
  _UserBookmarkTagPageState createState() => _UserBookmarkTagPageState();
}

class _UserBookmarkTagPageState extends State<UserBookmarkTagPage>
    with SingleTickerProviderStateMixin {
  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: PageHeader(
        title: Text(I18n.of(context).tag),
      ),
      content: NavigationView(
        pane: NavigationPane(items: [
          PaneItem(
            icon: const Icon(FluentIcons.public_folder),
            title: Text(I18n.of(context).public),
            body: const _TagTab(restrict: "public"),
          ),
          PaneItem(
            icon: const Icon(FluentIcons.lock),
            title: Text(I18n.of(context).private),
            body: const _TagTab(restrict: "private"),
          ),
        ], displayMode: PaneDisplayMode.top),
      ),
    );
  }
}

class _TagTab extends StatefulWidget {
  final String restrict;
  const _TagTab({required this.restrict});

  @override
  State<_TagTab> createState() => _TagTabState();
}

class _TagTabState extends State<_TagTab> {
  final EasyRefreshController _easyRefreshController = EasyRefreshController(
    controlFinishLoad: true,
    controlFinishRefresh: true,
  );
  late BookMarkTagStore _bookMarkTagStore;

  @override
  void initState() {
    super.initState();
    final userId = int.tryParse(accountStore.now?.userId ?? '');
    _bookMarkTagStore = BookMarkTagStore(
      userId ?? 0,
      _easyRefreshController,
    );
  }

  @override
  void dispose() {
    _easyRefreshController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Observer(
      builder: (_) {
        if (_bookMarkTagStore.errorMessage != null) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_bookMarkTagStore.errorMessage!),
                const SizedBox(height: 12),
                Button(
                  onPressed: () {
                    _bookMarkTagStore.fetch(widget.restrict);
                  },
                  child: Text(I18n.of(context).retry),
                ),
              ],
            ),
          );
        }
        return EasyRefresh(
          controller: _easyRefreshController,
          refreshOnStart: true,
          header: PixezDefault.header(context),
          footer: PixezDefault.footer(context),
          onRefresh: () async {
            await _bookMarkTagStore.fetch(widget.restrict);
          },
          onLoad: () async {
            await _bookMarkTagStore.next();
          },
          child: ListView.builder(
            itemBuilder: (context, index) {
              if (index == 0) {
                return ListTile(
                  title: Text(I18n.of(context).all),
                  onPressed: () {
                    Navigator.pop(
                        context, {"tag": null, "restrict": widget.restrict});
                  },
                );
              } else if (index == 1) {
                return ListTile(
                  title: Text(I18n.of(context).unclassified),
                  onPressed: () {
                    Navigator.pop(context,
                        {"tag": "未分類", "restrict": widget.restrict});
                  },
                );
              }
              final bookmarkTag =
                  _bookMarkTagStore.bookmarkTags[index - 2];
              return ListTile(
                title: Text(bookmarkTag.name),
                trailing: Text(bookmarkTag.count.toString()),
                onPressed: () {
                  Navigator.pop(context,
                      {"tag": bookmarkTag.name, "restrict": widget.restrict});
                },
              );
            },
            itemCount: _bookMarkTagStore.bookmarkTags.length + 2,
          ),
        );
      },
    );
  }
}
