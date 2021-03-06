#! /usr/bin/perl

# Copyright (C) 2016-2017 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

BEGIN {
    unshift @INC, 'lib';
    use FindBin;
    use Mojo::File qw(path tempdir);
    $ENV{OPENQA_BASEDIR} = path(tempdir, 't', 'full-stack.d');
    $ENV{OPENQA_CONFIG} = path($ENV{OPENQA_BASEDIR}, 'config')->make_path;
    # Since tests depends on timing, we require the scheduler to be fixed in its actions.
    $ENV{OPENQA_SCHEDULER_SCHEDULE_TICK_MS}   = 4000;
    $ENV{OPENQA_SCHEDULER_TIMESLOT}           = $ENV{OPENQA_SCHEDULER_SCHEDULE_TICK_MS};
    $ENV{OPENQA_SCHEDULER_MAX_JOB_ALLOCATION} = 1;
    $ENV{OPENQA_SCHEDULER_FIND_JOB_ATTEMPTS}  = 1;
    $ENV{OPENQA_SCHEDULER_CONGESTION_CONTROL} = 1;
    $ENV{OPENQA_SCHEDULER_BUSY_BACKOFF}       = 1;
    $ENV{OPENQA_SCHEDULER_MAX_BACKOFF}        = 8000;
    $ENV{OPENQA_SCHEDULER_WAKEUP_ON_REQUEST}  = 0;
    path($FindBin::Bin, "data")->child("openqa.ini")->copy_to(path($ENV{OPENQA_CONFIG})->child("openqa.ini"));
    path($FindBin::Bin, "data")->child("database.ini")->copy_to(path($ENV{OPENQA_CONFIG})->child("database.ini"));
    path($FindBin::Bin, "data")->child("workers.ini")->copy_to(path($ENV{OPENQA_CONFIG})->child("workers.ini"));
    path($ENV{OPENQA_BASEDIR}, 'openqa', 'db')->make_path->child("db.lock")->spurt;
    # DO NOT SET OPENQA_IPC_TEST HERE
}

# https://github.com/rurban/Cpanel-JSON-XS/issues/65
use JSON::PP;

use Mojo::Base -strict;
use lib "$FindBin::Bin/lib";
use Test::More;
use Test::Mojo;
use Test::Output 'stderr_like';
use Data::Dumper;
use IO::Socket::INET;
use POSIX '_exit';
use Fcntl ':mode';
use DBI;

# optional but very useful
eval 'use Test::More::Color';
eval 'use Test::More::Color "foreground"';

use File::Path qw(make_path remove_tree);
use Module::Load::Conditional 'can_load';
use OpenQA::Test::Utils qw(create_websocket_server create_resourceallocator start_resourceallocator setup_share_dir);

plan skip_all => "set FULLSTACK=1 (be careful)" unless $ENV{FULLSTACK};
plan skip_all => 'set TEST_PG to e.g. DBI:Pg:dbname=test" to enable this test' unless $ENV{TEST_PG};


my $workerpid;
my $wspid;
my $schedulerpid;
my $resourceallocatorpid;
my $sharedir = setup_share_dir($ENV{OPENQA_BASEDIR});

sub turn_down_stack {
    if ($workerpid) {
        kill TERM => $workerpid;
        waitpid($workerpid, 0);
    }

    if ($wspid) {
        kill TERM => $wspid;
        waitpid($wspid, 0);
    }

    if ($schedulerpid) {
        kill TERM => $schedulerpid;
        waitpid($schedulerpid, 0);
    }

    if ($resourceallocatorpid) {
        kill TERM => $resourceallocatorpid;
        waitpid($resourceallocatorpid, 0);
    }
}

sub kill_worker {
    # now kill the worker
    kill TERM => $workerpid;
    is(waitpid($workerpid, 0), $workerpid, 'WORKER is done');
    $workerpid = undef;
}

use OpenQA::SeleniumTest;

# skip if appropriate modules aren't available
unless (check_driver_modules) {
    plan skip_all => $OpenQA::SeleniumTest::drivermissing;
    exit(0);
}
path($ENV{OPENQA_CONFIG})->child("database.ini")->to_string;
ok -e path($ENV{OPENQA_BASEDIR}, 'openqa', 'db')->child("db.lock");
ok(open(my $conf, '>', path($ENV{OPENQA_CONFIG})->child("database.ini")->to_string));
print $conf <<"EOC";
[production]
dsn = $ENV{TEST_PG}
EOC
close($conf);

# drop the schema from the existant database
my $dbh = DBI->connect($ENV{TEST_PG});
$dbh->do('SET client_min_messages TO WARNING;');
$dbh->do('drop schema if exists public cascade;');
$dbh->do('CREATE SCHEMA public;');
$dbh->disconnect;

is(system("perl ./script/initdb --init_database"), 0);
# make sure the assets are prefetched
ok(Mojolicious::Commands->start_app('OpenQA::WebAPI', 'eval', '1+0'));

$schedulerpid = fork();
if ($schedulerpid == 0) {
    use OpenQA::Scheduler;
    OpenQA::Scheduler::run;
    Devel::Cover::report() if Devel::Cover->can('report');
    _exit(0);
}

$resourceallocatorpid = start_resourceallocator;

# we don't want no fixtures
my $driver = call_driver(sub { });
my $mojoport = OpenQA::SeleniumTest::get_mojoport;

my $resultdir = path($ENV{OPENQA_BASEDIR}, 'openqa', 'testresults')->make_path;
ok -d $resultdir;

$driver->title_is("openQA", "on main page");
is($driver->find_element('#user-action a')->get_text(), 'Login', "noone logged in");
$driver->click_element_ok('Login', 'link_text');
# we're back on the main page
$driver->title_is("openQA", "back on main page");

# cleak away the tour
$driver->click_element_ok('dont-notify', 'id');
$driver->click_element_ok('confirm',     'id');

my $wsport = $mojoport + 1;
$wspid = create_websocket_server($wsport);

my $connect_args = "--apikey=1234567890ABCDEF --apisecret=1234567890ABCDEF --host=http://localhost:$mojoport";

sub client_output {
    my ($args) = @_;
    open(my $client, "-|", "perl ./script/client $connect_args $args");
    my $out;
    while (<$client>) {
        $out .= $_;
    }
    close($client);
    return $out;
}

sub client_call {
    my ($args, $expected_out, $desc) = @_;
    my $out = client_output $args;
    is($?, 0, "Client $args succeeded");
    if ($expected_out) {
        like($out, $expected_out, $desc);
    }
}

my $JOB_SETUP
  = 'ISO=Core-7.2.iso DISTRI=tinycore ARCH=i386 QEMU=i386 QEMU_NO_KVM=1 '
  . 'FLAVOR=flavor BUILD=1 MACHINE=coolone QEMU_NO_TABLET=1 INTEGRATION_TESTS=1'
  . 'QEMU_NO_FDC_SET=1 CDMODEL=ide-cd HDDMODEL=ide-drive VERSION=1 TEST=core PUBLISH_HDD_1=core-hdd.qcow2';

# schedule job
client_call("jobs post $JOB_SETUP");

# verify it's displayed scheduled
$driver->click_element_ok('All Tests', 'link_text');
$driver->title_is('openQA: Test results', 'tests followed');
like($driver->get_page_source(), qr/\Q<h2>1 scheduled jobs<\/h2>\E/, '1 job scheduled');
wait_for_ajax;

my $job_name = 'tinycore-1-flavor-i386-Build1-core@coolone';
$driver->find_element_by_link_text('core@coolone')->click();
$driver->title_is("openQA: $job_name test results", 'scheduled test page');
like($driver->find_element('#result-row .panel-body')->get_text(), qr/State: scheduled/, 'test 1 is scheduled');
javascript_console_has_no_warnings_or_errors;

sub start_worker {
    $workerpid = fork();
    if ($workerpid == 0) {
        exec("perl ./script/worker --instance=1 $connect_args --isotovideo=../os-autoinst/isotovideo --verbose");
        die "FAILED TO START WORKER";
    }
}

start_worker;

sub wait_for_result_panel {
    my ($result_panel, $desc) = @_;

    for (my $count = 0; $count < 130; $count++) {
        last if $driver->find_element('#result-row .panel-body')->get_text() =~ $result_panel;
        sleep 1;
    }
    javascript_console_has_no_warnings_or_errors;
    $driver->refresh();
    like($driver->find_element('#result-row .panel-body')->get_text(), $result_panel, $desc);
}

sub wait_for_job_running {
    wait_for_result_panel qr/State: running/, 'job is running';
    $driver->find_element_by_link_text('Live View')->click();
}
wait_for_job_running;
wait_for_result_panel qr/Result: passed/, 'test 1 is passed';

ok(-s path($resultdir, '00000', "00000001-$job_name")->make_path->child('autoinst-log.txt'), 'log file generated');
ok(-s path($sharedir, 'factory', 'hdd')->make_path->child('core-hdd.qcow2'), 'image of hdd uploaded');
my $mode = S_IMODE((stat(path($sharedir, 'factory', 'hdd')->child('core-hdd.qcow2')))[2]);
is($mode, 420, 'exported image has correct permissions (420 -> 0644)');

my $post_group_res = client_output "job_groups post name='New job group'";
my $group_id       = ($post_group_res =~ qr/{ *id *=> *([0-9]*) *}\n/);
ok($group_id, 'regular post via client script');
client_call(
    "jobs/1 put --json-data '{\"group_id\": $group_id}'",
    qr/\Q{ job_id => 1 }\E/,
    'send JSON data via client script'
);
client_call('jobs/1', qr/group_id *=> *$group_id/, 'group has been altered correctly');

client_call('jobs/1/restart post', qr{\Qtest_url => ["/tests/2\E}, 'client returned new test_url');
$driver->refresh();
like($driver->find_element('#result-row .panel-body')->get_text(), qr/Cloned as 2/, 'test 1 is restarted');
$driver->click_element_ok('2', 'link_text');

wait_for_job_running;

kill_worker;

wait_for_result_panel qr/Result: incomplete/, 'test 2 crashed';
like(
    $driver->find_element('#result-row .panel-body')->get_text(),
    qr/Cloned as 3/,
    'test 2 is restarted by killing worker'
);

client_call("jobs post $JOB_SETUP MACHINE=noassets HDD_1=nihilist_disk.hda");

$driver->click_element_ok('All Tests',    'link_text', 'All tests clicked');
$driver->click_element_ok('core@coolone', 'link_text', 'clicked on 3');

# it can happen that the test is assigned and needs to wait for the scheduler
# to detect it as dead before it's moved back to scheduled
wait_for_result_panel qr/State: scheduled/, 'Test 3 is scheduled';
$driver->click_element_ok('cancel_running', 'id', 'Caught cancel');
$driver->click_element_ok('All Tests',      'link_text');
$driver->click_element_ok('core@noassets',  'link_text');

$job_name = 'tinycore-1-flavor-i386-Build1-core@noassets';
$driver->title_is("openQA: $job_name test results", 'scheduled test page');
like($driver->find_element('#result-row .panel-body')->get_text(), qr/State: scheduled/, 'test 4 is scheduled');

javascript_console_has_no_warnings_or_errors;
start_worker;

wait_for_result_panel qr/Result: incomplete/, 'Test 4 crashed as expected';

# Slurp the whole file, it's not that big anyways
my $filename = $resultdir . "/00000/00000004-$job_name/autoinst-log.txt";
# give it some time to be created
for (my $i = 0; $i < 5; $i++) {
    last if -s $filename;
    sleep 1;
}
#  The worker is launched with --verbose, so by default in this test the level is always debug
if (!$ENV{MOJO_LOG_LEVEL} || $ENV{MOJO_LOG_LEVEL} =~ /DEBUG|INFO/i) {
    ok(-s $filename, 'Test 4 autoinst-log.txt file created');
    open(my $f, '<', $filename) or die "OPENING $filename: $!\n";
    my $autoinst_log = do { local ($/); <$f> };
    close($f);

    like($autoinst_log, qr/result: setup failure/, 'Test 4 state correct: setup failure');

    like((split(/\n/, $autoinst_log))[0], qr/\[info\] \+\+\+ setup notes \+\+\+/,
        'Test 4 correct autoinst setup notes');
    like(
        (split(/\n/, $autoinst_log))[-1],
        qr/\[info\] uploading autoinst-log.txt/,
        'Test 4 correct autoinst uploading autoinst'
    );
}

kill_worker;    # Ensure that the worker can be killed with TERM signal

my $cache_location = path($ENV{OPENQA_BASEDIR}, 'cache')->make_path;
ok(-e $cache_location, "Setting up Cache directory");

open($conf, '>', path($ENV{OPENQA_CONFIG})->child("workers.ini")->to_string);
print $conf <<EOC;
[global]
CACHEDIRECTORY = $cache_location
CACHELIMIT = 50;

[http://localhost:$mojoport]
TESTPOOLSERVER = $sharedir/tests
EOC
close($conf);

ok(-e path($ENV{OPENQA_CONFIG})->child("workers.ini"), "Config file created.");

# For now let's repeat the cache tests before extracting to separate test
subtest 'Cache tests' => sub {

    my $filename;
    open($filename, '>', $cache_location->child("test.file"));
    print $filename "Hello World";
    close($filename);

    path($cache_location, "test_directory")->make_path;

    my $db_file  = $cache_location->child('cache.sqlite');
    my $job_name = 'tinycore-1-flavor-i386-Build1-core@coolone';
    client_call('jobs/3/restart post', qr{\Qtest_url => ["/tests/5\E}, 'client returned new test_url');

    $driver->get('/tests/5');
    like($driver->find_element('#result-row .panel-body')->get_text(), qr/State: scheduled/, 'test 5 is scheduled');
    ok(!-e $db_file, "cache.sqlite is not present");
    start_worker;
    wait_for_job_running;
    ok(-e $db_file, "cache.sqlite file created");
    ok(!-d path($cache_location, "test_directory"), "Directory within cache, not present after deploy");
    ok(!-e $cache_location->child("test.file"), "File within cache, not present after deploy");

    like(
        readlink(path($ENV{OPENQA_BASEDIR}, 'openqa', 'pool', '1')->child("Core-7.2.iso")),
        qr($cache_location/Core-7.2.iso),
        "iso is symlinked to cache"
    );

    wait_for_result_panel qr/Result: passed/, 'test 5 is passed';
    kill_worker;

    #  The worker is launched with --verbose, so by default in this test the level is always debug
    if (!$ENV{MOJO_LOG_LEVEL} || $ENV{MOJO_LOG_LEVEL} =~ /DEBUG|INFO/i) {
        $filename = path($resultdir, '00000', "00000005-$job_name")->child("autoinst-log.txt");
        open(my $f, '<', $filename) or die "OPENING $filename: $!\n";
        my $autoinst_log = do { local ($/); <$f> };
        close($f);

        like($autoinst_log, qr/Downloading Core-7.2.iso/, 'Test 5, downloaded the right iso.');
        like($autoinst_log, qr/11116544/,                 'Test 5 Core-7.2.iso size is correct.');
        like($autoinst_log, qr/\[info\] result: done/,    'Test 5 result done');
        like(
            (split(/\n/, $autoinst_log))[0],
            qr/\[info\] \+\+\+ setup notes \+\+\+/,
            'Test 5 correct autoinst setup notes'
        );
        like(
            (split(/\n/, $autoinst_log))[-1],
            qr/\[info\] uploading autoinst-log.txt/,
            'Test 5 correct autoinst uploading autoinst'
        );
    }
    my $dbh
      = DBI->connect("dbi:SQLite:dbname=$db_file", undef, undef, {RaiseError => 1, PrintError => 1, AutoCommit => 1});
    my $sql    = "SELECT * from assets order by last_use asc";
    my $sth    = $dbh->prepare($sql);
    my $result = $dbh->selectrow_hashref($sql);
    # We know it's going to be this host because it's what was defined in
    # the worker ini
    like($result->{filename}, qr/Core-7/, "Core-7.2.iso is the first element");

    for (1 .. 5) {
        $filename = $cache_location->child("$_.qcow2");
        open(my $tmpfile, '>', $filename);
        print $tmpfile $filename;
        $sql
          = "INSERT INTO assets (downloading,filename,etag,last_use) VALUES (0, ?, 'Not valid', strftime('%s','now'));";
        $sth = $dbh->prepare($sql);
        $sth->bind_param(1, $filename);
        $sth->execute();
        sleep 1;    # so that last_use is not the same for every item
    }

    # Mark the Core-7.2 iso as being downloaded to force the worker to wait for the lock later on.
    $sql = "update assets set downloading = 1 where filename = ? ";
    $dbh->prepare($sql)->execute($result->{filename});

    $sql    = "SELECT * from assets order by last_use desc";
    $sth    = $dbh->prepare($sql);
    $result = $dbh->selectrow_hashref($sql);
    like($result->{filename}, qr/5.qcow2$/, "file #5 is the newest element");

    # Delete image #5 so that it gets cleaned up when the worker is initialized.
    $sql = "delete from assets where filename = ? ";
    $dbh->prepare($sql)->execute($result->{filename});

    #simple limit testing.
    client_call('jobs/5/restart post', qr{\Qtest_url => ["/tests/6\E}, 'client returned new test_url');
    $driver->get('/tests/6');
    like($driver->find_element('#result-row .panel-body')->get_text(), qr/State: scheduled/, 'test 6 is scheduled');
    start_worker;
    wait_for_result_panel qr/Result: passed/, 'test 6 is passed';
    kill_worker;

    ok(!-e $result->{filename}, "asset 5.qcow2 removed during cache init");

    $sql    = "SELECT * from assets order by last_use desc";
    $sth    = $dbh->prepare($sql);
    $result = $dbh->selectrow_hashref($sql);

    like($result->{filename}, qr/Core-7/, "Core-7.2.iso the most recent asset again ");

    #simple limit testing.
    client_call('jobs/6/restart post', qr{\Qtest_url => ["/tests/7\E}, 'client returned new test_url');
    $driver->get('/tests/7');
    like($driver->find_element('#result-row .panel-body')->get_text(), qr/State: scheduled/, 'test 7 is scheduled');
    start_worker;
    wait_for_result_panel qr/Result: passed/, 'test 7 is passed';

    #  The worker is launched with --verbose, so by default in this test the level is always debug
    if (!$ENV{MOJO_LOG_LEVEL} || $ENV{MOJO_LOG_LEVEL} =~ /DEBUG|INFO/i) {
        $filename = path($resultdir, '00000', "00000007-$job_name")->child("autoinst-log.txt");
        ok(-s $filename, 'Test 7 autoinst-log.txt file created');

        open(my $f, '<', $filename) or die "OPENING $filename: $!\n";
        my $autoinst_log = do { local ($/); <$f> };
        close($f);

        like($autoinst_log, qr/Content has not changed/, 'Test 7 Core-7.2.iso has not changed.');
        like($autoinst_log, qr/\[info\] \+\+\+\ worker notes \+\+\+/, 'Test 7 correct autoinst worker notes');
        like(
            (split(/\n/, $autoinst_log))[0],
            qr/\[info\] \+\+\+ setup notes \+\+\+/,
            'Test 7 correct autoinst setup notes'
        );
        like(
            (split(/\n/, $autoinst_log))[-1],
            qr/\[info\] uploading autoinst-log.txt/,
            'Test 7 correct autoinst uploading autoinst'
        );
    }
    client_call("jobs post $JOB_SETUP HDD_1=non-existent.qcow2");
    $driver->get('/tests/8');
    wait_for_result_panel qr/Result: incomplete/, 'test 8 is incomplete';

    #  The worker is launched with --verbose, so by default in this test the level is always debug
    if (!$ENV{MOJO_LOG_LEVEL} || $ENV{MOJO_LOG_LEVEL} =~ /DEBUG|INFO/i) {
        $filename = path($resultdir, '00000', "00000008-$job_name")->child("autoinst-log.txt");
        ok(-s $filename, 'Test 8 autoinst-log.txt file created');

        open(my $f, '<', $filename) or die "OPENING $filename: $!\n";
        my $autoinst_log = do { local ($/); <$f> };
        close($f);

        like($autoinst_log, qr/\[info\] \+\+\+\ worker notes \+\+\+/, 'Test 7 correct autoinst worker notes');
        like(
            (split(/\n/, $autoinst_log))[0],
            qr/\[info\] \+\+\+ setup notes \+\+\+/,
            'Test 8 correct autoinst setup notes'
        );
        like(
            (split(/\n/, $autoinst_log))[-1],
            qr/\[info\] uploading autoinst-log.txt/,
            'Test 8 correct autoinst uploading autoinst'
        );

        like($autoinst_log, qr/non-existent.qcow2 failed with: 404 - Not Found/,
            'Test 8 failure message found in log.');
        like($autoinst_log, qr/result: setup failure/, 'Test 8 state correct: setup failure');
    }

    kill_worker;
};


subtest 'Isotovideo version' => sub {
    use OpenQA::Worker::Engines::isotovideo;
    use OpenQA::Worker;

    eval { OpenQA::Worker::Engines::isotovideo::set_engine_exec('/bogus/location'); };
    like($@, qr/Path to isotovideo invalid/, 'isotovideo version path invalid');
    OpenQA::Worker::init({}, {apikey => 123, apisecret => 456, instance => 1});
    is($OpenQA::Worker::Common::isotovideo_interface_version, 0, 'isotovideo worker init not set');

    OpenQA::Worker::Engines::isotovideo::set_engine_exec('../os-autoinst/isotovideo');
    ok($OpenQA::Worker::Common::isotovideo_interface_version > 0, 'isotovideo update version');

    $OpenQA::Worker::Common::isotovideo_interface_version = 0;
    OpenQA::Worker::init({},
        {apikey => 123, apisecret => 456, instance => 1, isotovideo => '../os-autoinst/isotovideo'});
    ok($OpenQA::Worker::Common::isotovideo_interface_version > 0, 'isotovideo worker init');
};

kill_driver;
turn_down_stack;
done_testing;

# in case it dies
END {
    kill_driver;
    turn_down_stack;
    $? = 0;
}
