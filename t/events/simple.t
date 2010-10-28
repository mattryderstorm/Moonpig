use Test::Routine;
use Test::Routine::Util;

use Test::More;
use Test::Fatal;
use Test::Deep qw(cmp_deeply all ignore methods superhashof);

use Moonpig::Util qw(event);

use t::lib::Class::Ledger::ImplicitEvents;

with(
  't::lib::Factory::Ledger',
  't::lib::Factory::EventHandler',
);

test generic_event_test => sub {
  my ($self) = @_;

  my $ledger = $self->test_ledger;

  my $noop_h = $self->make_event_handler(Noop => { });

  my $code_h = $self->make_event_handler('t::Test');

  $ledger->register_event_handler('test.noop', 'nothing',  $noop_h);

  $ledger->register_event_handler('test.code', 'callback', $code_h);

  $ledger->register_event_handler('test.both', 'bothnoop',  $noop_h);
  $ledger->register_event_handler('test.both', 'bothcode', $code_h);

  $ledger->handle_event(event( 'test.noop', { foo => 1 }));

  $ledger->handle_event(event( 'test.code', { foo => 2 }));

  $ledger->handle_event(event( 'test.both', { foo => 3 }));

  cmp_deeply(
    [ $code_h->calls ],
    [
      [
        $ledger,
        all(
          Test::Deep::isa('Moonpig::Events::Event'),
          methods(
            ident   => 'test.code',
            payload => { foo => 2 },
          ),
        ),
        superhashof({ event_guid => ignore(), handler_name => 'callback' }),
      ],
      [
        $ledger,
        all(
          Test::Deep::isa('Moonpig::Events::Event'),
          methods(
            ident   => 'test.both',
            payload => { foo => 3 },
          ),
        ),
        superhashof({ event_guid => ignore(), handler_name => 'bothcode' }),
      ],
    ],
    "event handler callback-handler called as expected",
  );

  isnt(
    exception { $ledger->handle_event('test.unknown', { foo => 1 }) },
    undef,
    "receiving an unknown event is fatal",
  );
};

test implicit_events_and_overrides => sub {
  my ($self) = @_;

  my $ledger = $self->test_ledger('t::lib::Class::Ledger::ImplicitEvents');

  my $code_h = $self->make_event_handler('t::Test');

  $ledger->register_event_handler('test.code' => 'callback' => $code_h);

  # this one should be handled by the one we just registered
  $ledger->handle_event(event('test.code' => { foo => 1 }));

  # and this one should be handled by the implicit one
  $ledger->handle_event(event('test.both' => { foo => 2 }));

  cmp_deeply(
    [ $code_h->calls ],
    [
      [
        $ledger,
        all(
          Test::Deep::isa('Moonpig::Events::Event'),
          methods(
            ident   => 'test.code',
            payload => { foo => 1 },
          ),
        ),
        superhashof({ event_guid => ignore(), handler_name => 'callback' }),
      ],
    ],
    "we can safely, effectively replace an implicit handler",
  );

  cmp_deeply(
    [ $ledger->code_h->calls ],
    [
      [
        $ledger,
        all(
          Test::Deep::isa('Moonpig::Events::Event'),
          methods(
            ident   => 'test.both',
            payload => { foo => 2 },
          ),
        ),
        superhashof({ event_guid => ignore(), handler_name => 'callback' }),
      ],
    ],
    "the callback still handles things for which it wasn't overridden",
  );

  my $error = exception {
    $ledger->register_event_handler(
      'test.code',
      'callback', 
       $self->make_event_handler(Noop => { }),
    );
  };

  is(
    $error->ident,
    'duplicate handler',
    "we can't replace an explicit handler",
  );
};

run_me;
done_testing;