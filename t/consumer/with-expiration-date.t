use strict;
use warnings;

use Moonpig::Util -all;
use Test::Fatal;
use Test::More;
use Test::Routine;
use Test::Routine::Util;

use Moonpig::Context::Test -all, '$Context';

with 't::lib::Role::UsesStorage';

my $XID = "narf";

use t::lib::Factory qw(build);

sub jan {
  my ($dy) = @_;
  return Moonpig::DateTime->new(
    year => 2000, month => 1, day => $dy,
  );
}

sub ledger_and_consumer {
  my ($self) = @_;
  Moonpig->env->stop_clock_at(jan(1));
  my $stuff = build(consumer =>
                      { class => class('Consumer::FixedExpiration'),
                        expire_date => jan(3),
                        cost_amount => 1,
                        description => 'foo',
                        old_age     => days(0), # lame
                        replacement_mri    => Moonpig::URI->nothing(),
                        xid => $XID
                       });
  my ($ledger, $consumer) = @{$stuff}{qw(ledger consumer)};
};

test "no replacement" => sub {
  my ($self) = @_;
  Moonpig->env->storage->do_rw(sub {
    my ($ledger, $consumer) = $self->ledger_and_consumer;
    is($consumer->replacement_mri->as_string, "moonpig://nothing",
       "replacement: nothing");
    is($ledger->active_consumer_for_xid($XID), $consumer,
       "Set up active consumer for this xid");
  });
};

test "expiration" => sub {
  my ($self) = @_;
  Moonpig->env->storage->do_rw(sub {
    my ($ledger, $consumer) = $self->ledger_and_consumer;

    plan tests => 4 + 2;
    for my $day (1 .. 4) {
      Moonpig->env->stop_clock_at(jan($day));
      $ledger->handle_event(event('heartbeat'));
      ok(($day < 3 xor $consumer->is_expired), "expired on day $day?")
    }
    is($consumer->replacement_mri->as_string, "moonpig://nothing",
       "replacement: still nothing");
    is($ledger->active_consumer_for_xid($XID), undef,
       "No longer active consumer for this xid?");
  });
};

run_me;
done_testing;
