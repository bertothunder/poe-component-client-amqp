package POE::Component::Client::AMQP;

=head1 NAME

POE::Component::Client::AMQP - Asynchronous AMQP client implementation in POE

=head1 SYNOPSIS

  use POE::Component::Client::AMQP;

  Net::AMQP::Protocol->load_xml_spec('amqp0-8.xml');

  my $amq = Component::Client::AMQP->create(
      RemoteAddress => 'mq.domain.tld',
      Logger        => Log::Log4perl->get_logger(),
  );

  $amq->channel(1)->queue('frank')->subscribe(sub {
      my ($header, $content) = @_;

      $amq->channel(1)->queue($header->reply_to)->publish(
          "Message received"
      );
  });

  $amq->run();

=head1 DESCRIPTION 

This module implements the Advanced Message Queue Protocol (AMQP) TCP/IP client.  It's goal is to provide users with a quick and easy way of using AMQP while at the same time exposing the advanced functionality of the protocol if needed.

=cut

use strict;
use warnings;
use POE qw(
    Filter::Stream
    Component::Client::TCP
    Component::Client::AMQP::Channel
    Component::Client::AMQP::Queue
);
use Params::Validate qw(validate_with);
use Data::Dumper;
use YAML::XS qw(Dump);
use bytes;
use Net::AMQP;
use Net::AMQP::Common qw(:all);
use Scalar::Util qw(blessed);
use Carp;

our $VERSION = 0.1;

sub create {
    my $class = shift;

    my %self = validate_with(
        params => \@_,
        spec => {
            Alias => { default => 'amqp_client' },
            AliasTCP => { default => 'tcp_client' },

            RemoteAddress => 1,
            RemotePort    => { default => 5672 },
            Username      => { default => 'guest' },
            Password      => { default => 'guest' },
            VirtualHost   => { default => '/' },

            Logger        => 1,

            Callbacks     => { default => {} },
        },
        allow_extra => 1,
    );

    my $self = bless \%self, $class;

    POE::Session->create(
        object_states => [
            $self => [qw(
                _start
                server_send
                server_connected
            )],
        ],
    );

    POE::Component::Client::TCP->new(
        Alias         => $self->{AliasTCP},
        RemoteAddress => $self->{RemoteAddress},
        RemotePort    => $self->{RemotePort},
        Connected     => sub { $self->tcp_connected(@_) },
        ServerInput   => sub { $self->tcp_server_input(@_) },
        Filter        => 'POE::Filter::Stream',
    );

    return $self;
}

## Public Class Methods ###

sub on_startup {
    my $self = shift;

    push @{ $self->{Callbacks}{Startup} }, @_;
}

sub channel_create {
    my $self = shift;

    # Create the object (which gives us the id and alias)

    my $channel = POE::Component::Client::AMQP::Channel->create(
        server => $self,
    );

    # Request the AMQP creation of the channel

    $poe_kernel->post($channel->{Alias}, server_send =>
        Net::AMQP::Frame::Method->new(
            method_frame => Net::AMQP::Protocol::Channel::Open->new(),
        ),
    );

    return $channel;
}

sub channel {
    my ($self, $id) = @_;

    return POE::Component::Client::AMQP::Channel->find_or_create($id, $self);
}

## POE States ###

sub _start {
    my ($self, $kernel) = @_[OBJECT, KERNEL];

    $kernel->alias_set($self->{Alias});
}

sub server_send {
    my ($self, $kernel, @output) = @_[OBJECT, KERNEL, ARG0 .. $#_];

    my $opts = {};
    if (ref $output[0] && ref $output[0] eq 'HASH' && ! blessed $output[0]) {
        $opts = shift @output;
    }

    # The default channel is 0 unless we've created one
    $opts->{channel} ||= 0;

    while (my $output = shift @output) {
        if (! $output->isa("Net::AMQP::Frame")) {
            $self->{Logger}->error("Invalid type out server output:\n".Dump($output));
            next;
        }

        if ($output->isa('Net::AMQP::Frame::Method') && $output->method_frame->method_spec->{synchronous}) {
            # If we're calling a synchronous method, then the server won't send any other
            # synchronous replies of particular type(s) until this message is replied to.
            # Wait for replies of these type(s) and don't send other messages until they're
            # cleared.

            my $output_class = ref($output->method_frame);

            # FIXME: It appears that RabbitMQ won't let us do two disimilar synchronous requests at once
            if (my @waiting_classes = keys %{ $self->{wait_synchronous} }) {
                $self->{Logger}->debug("Class $waiting_classes[0] is already waiting; do nothing else until it's complete; defering");
                push @{ $self->{wait_synchronous}{$waiting_classes[0]}{process_after} }, [ $opts, $output, @output ];
                return;
            }

            if ($self->{wait_synchronous}{$output_class}) {
                # There are already other things waiting; enqueue this output
                $self->{Logger}->debug("Class $output_class is already synchronously waiting; defering this and subsequent output");
                push @{ $self->{wait_synchronous}{$output_class}{process_after} }, [ $opts, $output, @output ];
                return;
            }

            my $responses = $output_class->method_spec->{responses};

            if (keys %$responses) {
                $self->{Logger}->debug("Setting up synchronous callback for $output_class");
                $self->{wait_synchronous}{$output_class} = {
                    request  => $output,
                    callback => $opts->{synchronous_callback}, # optional
                    responses => $responses,
                    process_after => [],
                };
            }
        }

        my $raw_output = $output->to_raw_frame();
        $self->{Logger}->debug(
            "Sending to channel ".$output->channel.": \n"
            . Dump($output)
            . "raw [".length($raw_output)."]: ".show_invis($raw_output)
        );
        $output = $raw_output;

        $self->{HeapTCP}{server}->put($output);
    }
}

sub server_connected {
    my ($self, $kernel) = @_[OBJECT, KERNEL];

    $self->{Logger}->info("Connected to the AMQP server and ready to act");

    # Call the callbacks if present
    if ($self->{Callbacks}{Startup}) {
        foreach my $subref (@{ $self->{Callbacks}{Startup} }) {
            $subref->();
        }
    }
}

## Private Class Methods ###

sub tcp_connected {
    my $self = shift;
    my ($kernel, $heap) = @_[KERNEL, HEAP];

    $self->{Logger}->info("Connected to remote host");

    #$self->{Logger}->debug("Sending 4.2.2 Protocol Header");
    $heap->{server}->put( Net::AMQP::Protocol->header );

    $self->{HeapTCP} = $heap;
}

sub tcp_server_input {
    my $self = shift;
    my ($kernel, $heap, $input) = @_[KERNEL, HEAP, ARG0];

    #$self->{Logger}->debug("Server said [".length($input)."]: ".show_invis($input));

    my @frames = Net::AMQP->parse_raw_frames(\$input);
    FRAMES:
    foreach my $frame (@frames) {

        $self->{Logger}->debug("Server sent frame on channel ".$frame->channel.": \n".Dump($frame));

        if ($frame->isa('Net::AMQP::Frame::Method')) {
            my $method_frame = $frame->method_frame;

            # Check the 'wait_synchronous' hash to see if this response is a synchronous reply
            my $method_frame_class = ref $method_frame;
            if ($method_frame_class->method_spec->{synchronous}) {
                #$self->{Logger}->debug("Checking wait_synchronous against $method_frame_class: " . Dumper($self->{wait_synchronous}));
                my $matching_output_class;
                while (my ($output_class, $details) = each %{ $self->{wait_synchronous} }) {
                    next unless $details->{responses}{ $method_frame_class };
                    $matching_output_class = $output_class;
                    last;
                }
                if ($matching_output_class) {
                    $self->{Logger}->debug("Response type '$method_frame_class' found from waiting request '$matching_output_class'");
                    my $details = delete $self->{wait_synchronous}{$matching_output_class};
                    if (my $callback = delete $details->{callback}) {
                        $self->{Logger}->debug("Calling $matching_output_class callback");
                        $callback->();
                    }
                    foreach my $output (@{ $details->{process_after} }) {
                        $self->{Logger}->debug("Dequeueing items that blocked due to '$method_frame_class'");
                        $kernel->post($self->{Alias}, server_send => @$output);
                    }
                }
            }

            if ($frame->channel == 0) {
                if ($method_frame->isa('Net::AMQP::Protocol::Connection::Start')) {
                    $kernel->post($self->{Alias}, server_send =>
                        Net::AMQP::Frame::Method->new(
                            channel => 0,
                            method_frame => Net::AMQP::Protocol::Connection::StartOk->new(
                                client_properties => {
                                    platform    => 'Perl/POE',
                                    product     => __PACKAGE__,
                                    information => 'http://code.xmission.com/',
                                    version     => $VERSION,
                                },
                                mechanism => 'AMQPLAIN', # TODO - ensure this is in $method_frame{mechanisms}
                                response => { LOGIN => $self->{Username}, PASSWORD => $self->{Password} },
                                locale => 'en_US',
                            ),
                        ),
                    );
                    next FRAMES;
                }
                elsif ($method_frame->isa('Net::AMQP::Protocol::Connection::Tune')) {
                    $kernel->post($self->{Alias}, server_send =>
                        Net::AMQP::Frame::Method->new(
                            channel => 0,
                            method_frame => Net::AMQP::Protocol::Connection::TuneOk->new(
                                channel_max => 0,
                                frame_max => 131072,
                                heartbeat => 0,
                            ),
                        ),
                        Net::AMQP::Frame::Method->new(
                            channel => 0,
                            method_frame => Net::AMQP::Protocol::Connection::Open->new(
                                virtual_host => $self->{VirtualHost},
                                capabilities => '',
                                insist => 1,
                            ),
                        ),
                    );
                    next FRAMES;
                }
                elsif ($method_frame->isa('Net::AMQP::Protocol::Connection::OpenOk')) {
                    $kernel->post($self->{Alias}, 'server_connected');
                    next FRAMES;
                }
            }
        }

        if ($frame->channel != 0) {
            my $channel = POE::Component::Client::AMQP::Channel->find_or_create( $frame->channel, $self );
            $kernel->post($channel->{Alias}, server_input => $frame);
        }
        else {
            $self->{Logger}->error("Unhandled server input:\n".Dump($frame));
        }
    }
}

=head1 COPYRIGHT

Copyright (c) 2009 Eric Waters and XMission LLC (http://www.xmission.com/).  All rights reserved.  This program is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

The full text of the license can be found in the LICENSE file included with this module.

=head1 AUTHOR

Eric Waters <ewaters@gmail.com>

=cut

1;
