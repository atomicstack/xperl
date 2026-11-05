# Basic module loading test, plus OS/Perl/libssl information to assist
# with diagnosing later test failures

use lib 'inc';

use Test::Net::SSLeay;

sub tap_info { print '# ', @_, "\n" }

BEGIN {
    plan tests => 1;

    use_ok('Net::SSLeay');
}

tap_info("");
tap_info("Testing Net::SSLeay $Net::SSLeay::VERSION");
tap_info("");
tap_info("Perl information:");
tap_info("  Version:         '" . $]  . "'");
tap_info("  Executable path: '" . $^X . "'");
tap_info("");

my $version_num;
if (defined &Net::SSLeay::OpenSSL_version_num) {
    tap_info("Library version with OpenSSL_version_num():");
    $version_num = Net::SSLeay::OpenSSL_version_num();
} else {
    tap_info("Library version with SSLeay():");
    $version_num = Net::SSLeay::SSLeay();
}
tap_info("  OPENSSL_VERSION_NUMBER: " . sprintf("'0x%08x'", $version_num));
tap_info("");

my $have_openssl_version = defined &Net::SSLeay::OpenSSL_version;

tap_info("Library information with SSLeay_version()" . ($have_openssl_version ? " and OpenSSL_version()" : '') . ":");
tap_info("  SSLEAY_VERSION:              '" . Net::SSLeay::SSLeay_version(Net::SSLeay::SSLEAY_VERSION())  . "'");
tap_info("  SSLEAY_CFLAGS:               '" . Net::SSLeay::SSLeay_version(Net::SSLeay::SSLEAY_CFLAGS())   . "'");
tap_info("  SSLEAY_BUILT_ON:             '" . Net::SSLeay::SSLeay_version(Net::SSLeay::SSLEAY_BUILT_ON()) . "'");
tap_info("  SSLEAY_PLATFORM:             '" . Net::SSLeay::SSLeay_version(Net::SSLeay::SSLEAY_PLATFORM()) . "'");
tap_info("  SSLEAY_DIR:                  '" . Net::SSLeay::SSLeay_version(Net::SSLeay::SSLEAY_DIR())      . "'");

# This constant was added about the same time as OpenSSL_version()
if ($have_openssl_version) {
	tap_info("  OPENSSL_ENGINES_DIR:         '" . Net::SSLeay::OpenSSL_version(Net::SSLeay::OPENSSL_ENGINES_DIR()) . "'");
}

# These were added in OpenSSL 3.0.0
if (eval { Net::SSLeay::OPENSSL_MODULES_DIR(); 1; }) {
    tap_info("  OPENSSL_MODULES_DIR:         '" . Net::SSLeay::OpenSSL_version(Net::SSLeay::OPENSSL_MODULES_DIR())         . "'");
    tap_info("  OPENSSL_CPU_INFO:            '" . Net::SSLeay::OpenSSL_version(Net::SSLeay::OPENSSL_CPU_INFO())            . "'");
    tap_info("  OPENSSL_VERSION_STRING:      '" . Net::SSLeay::OpenSSL_version(Net::SSLeay::OPENSSL_VERSION_STRING())      . "'");
    tap_info("  OPENSSL_FULL_VERSION_STRING: '" . Net::SSLeay::OpenSSL_version(Net::SSLeay::OPENSSL_FULL_VERSION_STRING()) . "'");
}

# These were added in OpenSSL 3.0.0
if (defined &Net::SSLeay::OPENSSL_version_major) {
    tap_info("");
    tap_info("Library version information with OPENSSL_version_*():");
    tap_info("  OPENSSL_version_major():          '" . Net::SSLeay::OPENSSL_version_major() . "'");
    tap_info("  OPENSSL_version_minor():          '" . Net::SSLeay::OPENSSL_version_minor() . "'");
    tap_info("  OPENSSL_version_patch():          '" . Net::SSLeay::OPENSSL_version_patch() . "'");
    tap_info("  OPENSSL_version_pre_release():    '" . Net::SSLeay::OPENSSL_version_pre_release() . "'");
    tap_info("  OPENSSL_version_build_metadata(): '" . Net::SSLeay::OPENSSL_version_build_metadata() . "'");
    tap_info("");
    tap_info("Library information with OPENSSL_info():");
    tap_info("  OPENSSL_INFO_CONFIG_DIR:             '" . Net::SSLeay::OPENSSL_info(Net::SSLeay::OPENSSL_INFO_CONFIG_DIR())             . "'");
    tap_info("  OPENSSL_INFO_ENGINES_DIR:            '" . Net::SSLeay::OPENSSL_info(Net::SSLeay::OPENSSL_INFO_ENGINES_DIR())            . "'");
    tap_info("  OPENSSL_INFO_MODULES_DIR:            '" . Net::SSLeay::OPENSSL_info(Net::SSLeay::OPENSSL_INFO_MODULES_DIR())            . "'");
    tap_info("  OPENSSL_INFO_DSO_EXTENSION:          '" . Net::SSLeay::OPENSSL_info(Net::SSLeay::OPENSSL_INFO_DSO_EXTENSION())          . "'");
    tap_info("  OPENSSL_INFO_DIR_FILENAME_SEPARATOR: '" . Net::SSLeay::OPENSSL_info(Net::SSLeay::OPENSSL_INFO_DIR_FILENAME_SEPARATOR()) . "'");
    tap_info("  OPENSSL_INFO_LIST_SEPARATOR:         '" . Net::SSLeay::OPENSSL_info(Net::SSLeay::OPENSSL_INFO_LIST_SEPARATOR())         . "'");
    tap_info("  OPENSSL_INFO_SEED_SOURCE:            '" . Net::SSLeay::OPENSSL_info(Net::SSLeay::OPENSSL_INFO_SEED_SOURCE())            . "'");
    tap_info("  OPENSSL_INFO_CPU_SETTINGS:           '" . Net::SSLeay::OPENSSL_info(Net::SSLeay::OPENSSL_INFO_CPU_SETTINGS())           . "'");
}
