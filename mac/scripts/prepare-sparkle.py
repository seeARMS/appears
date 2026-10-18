#!/usr/bin/env python3
"""Make the pinned Sparkle build incapable of in-process networking or HTML notes.

Keep these small changes explicit and fail on upstream drift. Each invocation reads
the pinned git originals, so rebuilding is idempotent without resetting a checkout.
"""
import pathlib
import subprocess
import sys


def prepare(root):
    """Apply the privacy patches from pinned originals without rewriting equal files."""
    def write_if_changed(path, source):
        """Preserve the timestamp when the generated patch is already on disk."""
        target = root / path
        # Preserve timestamps on restored source so Xcode can reuse Sparkle's
        # compiled objects. Still derive every patch from the pinned originals.
        if not target.exists() or target.read_text() != source:
            target.write_text(source)

    def original(path):
        """Read an unmodified source file from the checkout's pinned Git revision."""
        return subprocess.check_output(["git", "-C", str(root), "show", f"HEAD:{path}"], text=True)

    def replace_once(text, before, after):
        """Apply one expected substitution, failing if upstream source has drifted."""
        if text.count(before) != 1:
            raise ValueError("Pinned Sparkle source changed; review the privacy patch")
        return text.replace(before, after)

    path = "Sparkle/SPUDownloadDriver.m"
    source = replace_once(original(path), "_downloader = [[SPUDownloader alloc] initWithDelegate:self];",
                          '@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Appears requires the isolated downloader service" userInfo:nil];')
    write_if_changed(path, source)

    path = "Sparkle/SUUpdateAlert.m"
    source = original(path).replace('#import "SUWKWebView.h"\n', "").replace('#import "SULegacyWebView.h"\n', "")
    start = source.index('    // "-apple-system-font"', source.index("- (void)_createReleaseNotesViewPreferringFormat:"))
    end = source.index("    assert(_releaseNotesSpinner != nil);", start)
    source = source[:start] + '''    // Native text only. Never instantiate a web view, even for an invalid feed.
    _releaseNotesView = [[SUTextViewReleaseNotesView alloc]
        initWithFontPointSize:(int)[NSFont systemFontSize] appcastItem:_updateItem
        host:_host delegate:_delegate prefersMarkdown:(preferredReleaseNotesFormat == SUReleaseNotesFormatMarkdown)
        customAllowedURLSchemes:@[]];

''' + source[end:]
    write_if_changed(path, source)

    path = "Sparkle.xcodeproj/project.pbxproj"
    source = original(path)
    for entry in [
        "723B5DAA1CF7AB6A00365F95 /* SPUDownloader.m in Sources */",
        "723ABFC5259D4CB300BDB4FA /* SUWKWebView.m in Sources */",
        "723ABF31259D062F00BDB4FA /* SULegacyWebView.m in Sources */",
    ]:
        source = replace_once(source, f"\t\t\t\t{entry},\n", "")
    write_if_changed(path, source)


if __name__ == "__main__":
    prepare(pathlib.Path(sys.argv[1]))
