package HashOptionsCompat;

use strict;
use warnings;
use Hash::Util ();
use XS::APItest ();
use XSLoader;

our $VERSION = '0.01';
XSLoader::load(__PACKAGE__, $VERSION);

{
    no warnings 'redefine';
    *XS::APItest::Hash::disable_hash_key_sharing = \&disable_sharing;
    *XS::APItest::Hash::shared_query_key = \&query_key;
    *Hash::Util::hash_storage_info = \&pointer_storage_info
        unless Hash::Util->can('hash_storage_info');
    *XS::APItest::Hash::shared_key_storage_info = \&pointer_shared_info
        unless XS::APItest::Hash->can('shared_key_storage_info');
}

1;
