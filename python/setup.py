"""Platform-specific wheel override.

The wheel is not pure Python — it carries a signed, notarized macOS `.app` bundle — so it must
be tagged for macOS/universal2 and marked impure. pip/uv then refuse to install it on non-macOS
rather than handing someone a package that can never work. The real minimum OS is enforced by the
bundle's `LSMinimumSystemVersion` (14.0), which is where that requirement already lives.
"""
from setuptools import setup

try:
    from wheel.bdist_wheel import bdist_wheel
except ImportError:  # pragma: no cover - newer wheel moved the module
    from setuptools.command.bdist_wheel import bdist_wheel


class PlatformSpecificWheel(bdist_wheel):
    def finalize_options(self):
        super().finalize_options()
        self.root_is_pure = False

    def get_tag(self):
        return "py3", "none", "macosx_14_0_universal2"


setup(cmdclass={"bdist_wheel": PlatformSpecificWheel})
