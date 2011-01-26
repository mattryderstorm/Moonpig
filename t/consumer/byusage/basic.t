use strict;
use warnings;

use Carp qw(confess croak);
use Moonpig::DateTime;
use Moonpig::Util -all;
use Test::Routine;
use Test::More;
use Test::Routine::Util;

has ledger => (
  is   => 'rw',
  does => 'Moonpig::Role::Ledger',
  default => sub { $_[0]->test_ledger() },
  lazy => 1,
  clearer => 'scrub_ledger',
);
sub ledger;  # Work around bug in Moose 'requires';

has consumer => (
  is   => 'rw',
  does => 'Moonpig::Role::Consumer::ByUsage',
  default => sub { $_[0]->test_consumer('ByUsage') },
  lazy => 1,
  clearer => 'discard_consumer',
  predicate => 'has_consumer',
);

has hold => (
  is   => 'rw',
  isa => 'Moonpig::Hold',
  clearer => 'discard_hold',
);

with(
  't::lib::Factory::Consumers',
  't::lib::Factory::Ledger',
);

use t::lib::Logger;

before run_test => sub {
  my ($self) = @_;
  $self->discard_consumer;
  $self->discard_hold;
  Moonpig->env->email_sender->clear_deliveries;
};

test create_consumer => sub {
  my ($self, $args) = @_;
  $args ||= {};
  return if $self->has_consumer;

  my $b = class('Bank')->new({
    ledger => $self->ledger,
    amount => dollars(1),
  });

  $self->consumer(
    $self->test_consumer(
      'ByUsage',
      { bank => $b,
        ledger => $self->ledger,
        %$args,
      }));
  ok($self->consumer, "set up consumer");
  ok($self->consumer->does('Moonpig::Role::Consumer::ByUsage'),
     "consumer is correct type");
  is($self->consumer->bank, $b, "consumer has bank");
  is($self->consumer->unapplied_amount, dollars(1), "bank contains \$1");
};

test successful_hold => sub {
  my ($self, $n_units) = @_;
  $n_units ||= 7;
  $self->create_consumer;
  is($self->consumer->units_remaining, 20, "initially funds for 20 units");
  my $h = $self->consumer->create_hold_for_units($n_units);
  my $amt = $n_units * cents(5);
  ok($h, "made hold");
  $self->hold($h);
  is($h->consumer, $self->consumer, "hold has correct consumer");
  is($h->bank, $self->consumer->bank, "hold has correct bank");
  is($h->amount, $amt, "hold is for $amt mc");
  my $x_remaining = 20 - $n_units;
  is($self->consumer->units_remaining, $x_remaining,
     "after holding $n_units, there are $x_remaining left");
};

test release_hold => sub {
  my ($self) = @_;
  $self->scrub_ledger;
  $self->successful_hold;
  is($self->consumer->units_remaining, 13, "still 13 left in bank");
  $self->hold->delete;
  is($self->consumer->units_remaining, 20, "20 left after releasing hold");
};

test commit_hold => sub {
  my ($self) = @_;
  my @journals;
  $self->successful_hold;
  @journals = $self->ledger->journals;
  is(@journals, 0, "no journal yet");
  note("creating charge for hold");
  $self->consumer->create_charge_for_hold($self->hold, "test charge");
  is($self->consumer->units_remaining, 13, "still 13 left in bank");
  @journals = $self->ledger->journals;
  is(@journals, 1, "now one journal");
  is($journals[0]->charge_tree->total_amount, cents(35),
     "total charges now \$.35");
};

test failed_hold => sub {
  my ($self) = @_;
  $self->successful_hold;
  is($self->consumer->units_remaining, 13, "still 13 left in bank");
  my $hold = $self->consumer->create_hold_for_units(14);
  is(undef(), $hold, "cannot create hold for 14 units");
  is($self->consumer->units_remaining, 13, "still 13 left in bank");
};

test low_water_replacement => sub {
  my ($self) = @_;
  my $MRI =
    Moonpig::URI->new("moonpig://test/method?method=construct_replacement");
  my $lwm = 7;
  $self->create_consumer({
    low_water_mark => $lwm,
    replacement_mri => $MRI,
    old_age => 0,
  });
  my $q = 2;
  my $held = 0;
  until ($self->consumer->has_replacement) {
    $self->consumer->create_hold_for_units($q) or last;
    $held += $q;
  }
  cmp_ok($self->consumer->units_remaining, '<=', $lwm,
         "replacement consumer created at or below LW mark");
  cmp_ok($self->consumer->units_remaining + $q, '>', $lwm,
         "replacement consumer created just below LW mark");
};

sub jan {
  my ($day) = @_;
  return feb($day-31) if $day > 31;
  Moonpig::DateTime->new( year => 2000, month => 1, day => $day );
}

sub feb {
  my ($day) = @_;
  Moonpig::DateTime->new( year => 2000, month => 2, day => $day );
}

test est_lifetime => sub {
  my ($self) = @_;
  Moonpig->env->current_time(jan(1));

  $self->create_consumer();
  is($self->consumer->units_remaining, 20, "initially 20 units");
  is($self->consumer->unapplied_amount, dollars(1), "initially \$1.00");
  is($self->consumer->estimated_lifetime, days(365),
     "inestimable lifetime -> 365d");

  Moonpig->env->current_time(jan(15));
  $self->consumer->create_hold_for_units(1);
  is($self->consumer->units_remaining, 19, "now 19 units");
  is($self->consumer->unapplied_amount, dollars(0.95), "now \$0.95");
  Moonpig->env->current_time(jan(30));
  is($self->consumer->estimated_lifetime, days(30 * 19),
     "1 charge/30d -> lifetime 600d");

  Moonpig->env->current_time(jan(24));
  $self->consumer->create_hold_for_units(2);
  is($self->consumer->units_remaining, 17, "now 17 units");
  is($self->consumer->unapplied_amount, dollars(0.85), "now \$0.85");
  Moonpig->env->current_time(jan(30));
  is($self->consumer->estimated_lifetime, days(30 * 17/3),
     "3 charges/30d -> lifetime 200d");

  Moonpig->env->current_time(jan(50));
  is($self->consumer->estimated_lifetime, days(30 * 17/2),
     "old charges don't count");

  Moonpig->env->current_time(jan(58));
  is($self->consumer->estimated_lifetime, days(365),
     "no recent charges -> guess 365d");
};

test est_lifetime_replacement => sub {
  my ($self) = @_;
  ok(1);
};

test low_water_check => sub {
  ok(1);
};

test expiration => sub {
  ok(1);
};

test subsidiary_hold => sub {
  ok(1);
};

run_me;
done_testing;
