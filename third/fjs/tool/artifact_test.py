"""Regression coverage for local SwiftPM binary cache invalidation."""
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import artifact

class SwiftPmArtifactTest(unittest.TestCase):
    def test_only_stale_generated_fjs_is_invalidated(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cache = root / 'build/macos/SourcePackages/artifacts/fjs'
            binary = cache / 'FjsBinary/fjs.xcframework/macos-arm64/fjs.framework/Versions/A/fjs'
            binary.parent.mkdir(parents=True)
            binary.write_text('old')
            other = cache.parent / 'other-package/keep'
            other.parent.mkdir(); other.write_text('keep')
            product = root / 'build/macos/Build/Products/Profile/fjs.framework'
            product.mkdir(parents=True)
            app = root / 'build/macos/Build/Products/Profile/Reveric.app/Contents/Frameworks/fjs.framework'
            app.mkdir(parents=True)
            with patch.object(artifact, 'ROOT', root), patch.object(artifact, 'binary_uuids', return_value={('OLD', '(arm64)')}):
                artifact.prepare_swiftpm({('NEW', '(arm64)')})
            self.assertFalse(cache.exists())
            self.assertFalse(product.exists())
            self.assertTrue(other.is_file())
            self.assertTrue(app.is_dir())

    def test_matching_cache_is_retained(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / 'build/macos/SourcePackages/artifacts/fjs/FjsBinary/fjs.xcframework/macos-arm64/fjs.framework/Versions/A/fjs'
            binary.parent.mkdir(parents=True); binary.write_text('current')
            with patch.object(artifact, 'ROOT', root), patch.object(artifact, 'binary_uuids', return_value={('NEW', '(arm64)')}):
                artifact.prepare_swiftpm({('NEW', '(arm64)')})
            self.assertTrue(binary.is_file())

    def test_stale_embedded_output_is_invalidated_without_removing_app(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / 'build/macos/SourcePackages/artifacts/fjs/FjsBinary/fjs.xcframework/macos-arm64/fjs.framework/Versions/A/fjs'
            binary.parent.mkdir(parents=True); binary.write_text('new')
            app = root / 'build/macos/Build/Products/Profile/Reveric.app'
            embedded = app / 'Contents/Frameworks/fjs.framework/fjs'
            embedded.parent.mkdir(parents=True); embedded.write_text('old')
            marker = app / 'Contents/keep'; marker.write_text('keep')
            with patch.object(artifact, 'ROOT', root), patch.object(artifact, 'binary_uuids', side_effect=lambda p: {('OLD' if p == embedded else 'NEW', '(arm64)')}):
                artifact.prepare_swiftpm({('NEW', '(arm64)')})
            self.assertFalse(embedded.parent.exists())
            self.assertEqual(binary.read_text(), 'new')
            self.assertEqual(marker.read_text(), 'keep')

if __name__ == '__main__':
    unittest.main()
