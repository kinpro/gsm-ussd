#!/usr/bin/perl
########################################################################
# vim: set expandtab sw=4 ts=4 ai nu: 
########################################################################
# Copyright (C) 2010 Jochen Gruse, jochen@zum-quadrat.de
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
# 
########################################################################

use strict;
use warnings;
use 5.008;                  # Encode::GSM0338 only vailable since 5.8

use Getopt::Long;
use Pod::Usage;
use Expect;
use Encode qw(encode decode);


########################################################################
# Init
########################################################################

my $modemport           = '/dev/ttyUSB1';   # AT port of a Huawei E160 modem
my $timeout_for_answer  = 20;               # Timeout for modem answers in seconds
my $ussd_query          = '*100#';          # Prepaid account query
my $use_cleartext       = undef;            # Need to encode USSD query?
my $show_online_help    = 0;                # Option flag online help
my $debug               = 0;                # Option flag debug mode
my $expect              = undef;            # The Expect object
my $expect_logfilename  = undef;            # Filename to log the modem dialog into
my $pin                 = undef;            # Value for option PIN
my @all_args            = @ARGV;            # Backup of args to print them for debug

# Consts
my $success = 1;
my $fail    = 0;

# Parse options and react to them
GetOptions (
    'modem|m=s'     =>	\$modemport,
    'timeout|t=i'	=>	\$timeout_for_answer,
	'pin|p=s'       =>	\$pin,
    'cleartext|c!'  =>  \$use_cleartext,
    'debug|d'       =>  \$debug,
    'logfile|l=s'	=>	\$expect_logfilename,
    'help|h|?'      =>	\$show_online_help,
) 
or pod2usage(-verbose => 0);

# Online help wanted?
if ( $show_online_help ) {
    pod2usage(-verbose => 1);
}

# Further arguments are USSD queries
if ( @ARGV != 0 ) {
    $ussd_query = $ARGV[0];
}

# The Expect programs differ in the way they react to modem answers
my %expect_programs = (
    # wait_for_OK:  The modem will react with OK/ERROR/+CM[SE] ERROR
    #               This in itself will be the result, further information
    #               might be available between AT... and OK.
    wait_for_OK =>  [
        # Ignore status messages
        [ qr/\r\n([\+\^](?:BOOT|DSFLOWRPT|MODE|RSSI|SIMST|SRVST)):[ ]*([^\r\n]*)\r\n/i
            => \&ignore_state_line
        ],
        # Identify +CREG status message
        # (+CREG modem answer has got two arguments "\d+, \d+"!)
        [ qr/\r\n(\+CREG):[ ]*(\d+)\r\n/i
            => \&ignore_state_line
        ],
        # Fail states of the modem (network lost, SIM problems, ...)
        [ qr/\r\n(\+CM[SE] ERROR):[ ]*([^\r\n]*)\r\n/i
            => \&network_error
        ],
        # AT command (TTY echo of input)
        [ qr/^AT([^\r\n]*)/i
            =>  sub {
                    my $exp = shift;
                    DEBUG("AT found, -> ",$exp->match() );
                    exp_continue_timeout;
                }
        ],
        # Modem answers to command
        [ qr/\r\n(OK|ERROR)\r\n/i
            =>  sub {
                    my $exp = shift;
                    DEBUG ("OK/ERROR found: ", ($exp->matchlist())[0] );
                }
        ],
    ],
    # wait_for_cmd_answer:
    #               The command answers with OK/ERROR, but the real
    #               result will arrive later out of the net
    wait_for_cmd_answer =>  [
        # Ignore status messages
        [ qr/\r\n(\^(?:BOOT|DSFLOWRPT|MODE|RSSI|SIMST|SRVST)):[ ]*([^\r\n]*)\r\n/i
            => \&ignore_state_line
        ],
        # Identify +CREG status message
        # (+CREG modem answer has got two arguments "\d+, \d+"!)
        [ qr/\r\n(\+CREG):[ ]*(\d+)\r\n/i
            => \&ignore_state_line
        ],
        # Fail states of the modem (network lost, SIM problems, ...)
        [ qr/\r\n(\+CM[SE] ERROR):[ ]*([^\r\n]*)\r\n/i
            =>  \&network_error
        ],
        # The expected result - all state messages have already been
        # dealt with. Everything that reaches this part has to be the
        # result of the sent command.
        # Some more checks of that?
        [ qr/\r\n(\+[^:]+):[ ]*([^\r\n]*)\r\n/i
            => sub {
                my $exp = shift;
                my $match = $exp->match();
                $match =~ s/(?:^\s+|\s+$)//g;
                DEBUG ("Expected answer: ", $match);
            }
        ],
        # AT command (TTY echo of input)
        [ qr/^AT([^\r\n]*)/i
            =>  sub {
                    my $exp = shift;
                    DEBUG("AT found, -> ",$exp->match() );
                    exp_continue_timeout;
                }
        ],
        # OK means that the query was successfully sent into the
        # net. Carry on!
        [ qr/\r\n(OK)\r\n/i
            =>  sub {
                    DEBUG ("OK found, continue waiting for result"); 
                    exp_continue;
                }
        ],
        # ERROR means that the command wasn't syntactically correct
        # oder couldn't be understood (wrong encoding?). Stop here,
        # as no more meaningful results can be expected.
        [ qr/\r\n(ERROR)\r\n/i
            =>  sub {
                    DEBUG ("ERROR found, aborting"); 
                }
        ],
    ],
);


########################################################################
# Main
########################################################################
DEBUG ("Start, Args: ", @all_args);
DEBUG ("Setting output to UTF-8");
binmode (STDOUT, ':utf8');

check_modemport ($modemport);

DEBUG ("Opening modem");
if ( ! open MODEM, '+<', $modemport ) {
	print STDERR "Can't open modem device \"$modemport\": $!";
    exit 1;
}

DEBUG ("Initialising Expect");
$expect	= Expect->exp_init(\*MODEM);
if (defined $expect_logfilename) {
    $expect->log_file($expect_logfilename, 'w');
}

if ( ! check_for_modem() ) {
    print STDERR "No modem found at device \"$modemport\". Possible causes:\n";
    print STDERR "* Wrong modem device (use -m <dev>?)\n";
    print STDERR "* Modem broken (no reaction to AT)\n";
    exit 1;
}

my $modem_model = get_modem_model();
if ( ! defined $modem_model ) {
    $modem_model = '';
}
if ( ! defined $use_cleartext ) {
    if ( $modem_model !~ /^E160/ ) {
        DEBUG ("Modem is not a Huawei E160, switching to cleartext");
        $use_cleartext = 1;
    }
    else {
        $use_cleartext = 0;
    }
}
else {
    $use_cleartext = 0;
}

if ( pin_needed() ) {
    DEBUG ("PIN needed");
    if ( ! defined $pin ) {
        print STDERR "SIM card is locked, but no PIN to unlock given.\n";
        print STDERR "Use \"-p <pin>\"!\n";
        exit 1;
    }
    if ( enter_pin ($pin) ) {
        DEBUG ("Pin $pin accepted, waiting for 10 seconds");
        sleep 10;
    }
    else {
        print STDERR "SIM card is locked, PIN $pin not accepted!\n";
        print STDERR "Start me again with the correct PIN!\n";
        exit 1;
    }
}

my $ussd_result = do_ussd_query();
if ( $ussd_result->{ok} ) {
    print $ussd_result->{msg}, $/;
}
else {
    print STDERR $ussd_result->{msg}, $/;
    exit 1;
}

DEBUG ("Closing modem");
close MODEM;

DEBUG ("End");
exit 0;

########################################################################
# Subs
########################################################################

########################################################################
# Function: check_modemport
# Args:     File to check as modem port
# Returns:  void, exits if modem port check fails
sub check_modemport {
    my ($mp) = @_;

    if ( ! -e $mp ) {
        print STDERR "Modem port \"$mp\" doesn't exist. Possible causes:\n";
        print STDERR "* Modem not plugged in/connected\n";
        print STDERR "* Modem broken\n";
        print STDERR "Perhaps use another device with -m?\n";
        exit 1;
    }

    if ( ! -r $mp ) {
        print STDERR "Can't read from device \"$mp\".\n";
        print STDERR "Set correct rights for \"$mp\" with chmod?\n";
        print STDERR "Perhaps use another device with -m?\n";
        exit 1;
    }

    if ( ! -w $mp ) {
        print STDERR "Can't write to device \"$mp\".\n";
        print STDERR "Set correct rights for \"$mp\" with chmod?\n";
        print STDERR "Perhaps use another device with -m?\n";
        exit 1;
    }

    if ( ! -c $mp ) {
        print STDERR "Modem device \"$mp\" is no device file. Possible causes:\n";
        print STDERR "* Wrong device file given (-m ?)\n";
        print STDERR "* Device file broken?\n";
        print STDERR "Please check!\n";
        exit 1;
    }
}

########################################################################
# Function: check_for_modem
# Args:     None
# Returns:  0   No modem found 
#           1   Modem found
#
# "Finding a modem" is hereby defined as getting a reaction of "OK"
# to sending "AT" at the file handle in question.
sub check_for_modem {

    DEBUG ("Starting modem check (AT)");
    my $result = send_command ( "AT", 'wait_for_OK' );
    if ( $result->{ok} ) {
        DEBUG ("Modem found (AT->OK)");
        return 1;
    }
    else {
        DEBUG ("No modem found, error: $result->{description}");
        return 0;
    }
}


########################################################################
# Function: get_modem_model
# Args:     None
# Returns:  String  Name of the modem model
#           undef   No name found
sub get_modem_model {

    DEBUG ("Querying modem type");
    my $result = send_command ( "AT+CGMM", 'wait_for_OK' );
    if ( $result->{ok} ) {
        DEBUG ("Modem type found: ", $result->{description} );
        return $result->{description};
    }
    else {
        DEBUG ("No modem type found: ", $result->{description});
        return undef;
    }
}

########################################################################
# Function: pin_needed
# Args:     None.
# Returns:  0   No PIN needed, SIM card is unlocked
#           1   PIN (or PUK) still needed, SIM card still locked
sub pin_needed {

    DEBUG ("Starting SIM state query (AT+CPIN?)");
    my $result = send_command ( 'AT+CPIN?', 'wait_for_OK' );
    if ( $result->{ok} ) {
        DEBUG ("Got answer for SIM state query");
        if ( $result->{match} eq 'OK') {
            if ( $result->{description} =~ m/READY/ ) {
                DEBUG ("SIM card is unlocked");
                return 0;
            }
            elsif ( $result->{description} =~ m/SIM PIN/ ) {
                DEBUG ("SIM card is locked");
                return 1;
            }
            else {
                DEBUG ("Couldn't parse SIM state query result: " . $result->{description});
                return 1;
            }
        }
        else {
            DEBUG ("SIM card locked - failed query? -> " . $result->{match} );
            return 1;
        }
    }
    else {
        DEBUG (" SIM state query failed, error: " . $result->{description} );
        return 1;
    }
}


########################################################################
# Function: enter_pin
# Args:     The PIN to unlock the SIM card
# Returns:  0   Unlocking the SIM card failed
#           1   SIM is now unlocked
sub enter_pin {
    my ($pin) = @_;

    DEBUG ("Unlocking SIM using PIN $pin");
    my $result = send_command ( "AT+CPIN=$pin", 'wait_for_OK' );
    if ( $result->{ok} ) {
        DEBUG ("SIM card unlocked: ", $result->{match} );
        return 1;
    }
    else {
        DEBUG ("SIM card still locked, error: ", $result->{description});
        return 0;
    }
}

########################################################################
# Function: do_ussd_query
# Args:     None.
# Returns:  undef   No expected answer, timeout, error
#           String  The received message with the answer to the USSD
#                   query.
sub do_ussd_query {

    DEBUG ("Starting USSD query");
    my $result = send_command ( ussd_query_cmd($ussd_query, $use_cleartext), 'wait_for_cmd_answer' );
    if ( $result->{ok} ) {
        DEBUG ("USSD query succesful, answer received");
        my ($val1,$hexstring,$encoding) = $result->{description} =~ m/(\d+),"([^"]+)",(\d+)/i;
        if ( ! defined $encoding ) {
            # Hat der RA nicht gepasst?
            DEBUG ("Couldn't parse CUSD message: \"", $result->{description}, "\"");
            return { ok => $fail, msg => "Couldn't understand modem answer: \"" . $result->{description} . "\"" };
        }
        elsif ( $encoding == 0 ) {
            return { ok => $success, msg => hex_to_string( $hexstring ) };
        }
        elsif ( $encoding == 15 ) {
            return { ok => $success, msg => decode_text( $hexstring ) };
        }
        else {
            DEBUG ("CUSD message has unknown encoding \"$encoding\", using 0");
            return { ok => $success, msg => hex_to_string ($hexstring) };
        }
    }
    else {
        DEBUG ("USSD query failed, error: " . $result->{description});
        return { ok => $fail, msg => $result->{description} };
    }
}

########################################################################
# Function: send_command
# Args:     $cmd        String holding the command to send (usually 
#                       something like "AT...")
#           $how_to_react
#                       String explaining which Expect program to use:
#                       wait_for_OK
#                           return immediately in case of OK/ERROR
#                       wait_for_cmd_answer
#                           Break in case of ERROR, but wait for 
#                           the real result after OK
# Returns:  Hash ref   Result of sent command
sub send_command {
    my ($cmd, $how_to_react)	= @_;

    DEBUG ("Sending command: $cmd");
    $expect->send("$cmd\015");

    my (
        $matched_pattern_pos,
        $error,
        $match_string,
        $before_match,
        $after_match
    ) =
    $expect->expect (
            $timeout_for_answer,
            @{$expect_programs{$how_to_react}},
        );

    if ( !defined $error ) {
        my ($first_word, $args ) = $expect->matchlist();
        $first_word = uc $first_word;
        $match_string =~ s/(?:^\s+|\s+$)//g;    # crop whitespace
        if ( $first_word eq 'ERROR' ) {
            # OK/ERROR sind die zwei der drei "Kommando beendet"-Anzeiger.
            return { ok => $fail, match => $match_string, description => 'Broken command' } ;
        }
        elsif ( $first_word eq '+CMS ERROR' || $first_word eq '+CME ERROR' ) {
            # Nach diesen Fehlern kommt auch kein OK/ERROR mehr
            return { ok => $fail, match => $match_string, description => "Network error: $args" } ;
        }
        elsif ( $first_word eq 'OK' ) {
            # $before_match enthaelt die Daten zwischen AT und OK
            $before_match =~ s/(?:^\s+|\s+$)//g;    # crop whitespace
            return { ok => $success, match => $match_string, description => $before_match } ;
        }
        elsif ( $first_word =~ /^[\^\+]/ ) {
            return { ok => $success, match => $match_string, description => $match_string } ;
        }
        else {
            return { ok => $fail, match => $match_string, description => "PANIC! Can't parse Expect result: \"$match_string\"" } ;
        }
    }
    else {
        # Expect-Error melden & aussteigen
        if ($error =~ /^1:/) {
            # Timeout
            return { ok => $fail, match => $error, description => "No answer for $timeout_for_answer seconds!" };
        }
        elsif ($error =~ /^2:/) {
            # EOF
            return { ok => $fail, match => $error, description => "EOF from modem received - modem unplugged?" };
        }
        elsif ($error =~ /^3:/) {
            # Spawn id died
            return { ok => $fail, match => $error, description => "PANIC! Can't happen - spawn ID died!" };
        }
        elsif ($error =~ /^4:/) {
            # Read error
            return { ok => $fail, match => $error, description => "Read error accessing modem: $!" };
        }
        else {
            return { ok => $fail, match => $error, description => "PANIC! Can't happen - unknown Expect error \"$error\"" };
        }
    }
    return { ok => $fail, match => '', description => "PANIC! Can't happen - left send_command() unexpectedly!" };
}

########################################################################
# Function: ignore_state_line
# Args:     $state_name Name of state message
#           $result     Value if state message
# Returns:  Nothing, but continues the expect()-call if state message is
#           harmless.
sub ignore_state_line {
    my $exp = shift;
    my ($state_name, $result) = $exp->matchlist();

    DEBUG("$state_name: $result, ignored");
    exp_continue_timeout;
}

########################################################################
# Function: network_error
# Args:     $state_msg_type    Type of state message
#           $state_msg_result  Value of state message
# Returns:  Always 0, which will cause the calling function to end
#           the expect() call.
sub network_error {
    my $exp = shift;
    my ($error_msg_type,$error_msg_value) = $exp->matchlist();

    DEBUG ("Network error $error_msg_type with data \"$error_msg_value\" detected.");
}

########################################################################
# Function: ussd_query_cmd
# Args:     The USSD-Query to send 
# Returns:  An AT+CUSD command with properly encoded args
sub ussd_query_cmd {
	my ($ussd_cmd)                  = @_;
	my $result_code_presentation    = '1';      # Enable result code presentation
	my $encoding                    = '15';     # No clue, what this value means
	my $ussd_string;
    if ( $use_cleartext ) {
        $ussd_string = $ussd_cmd;
    }
    else {
        $ussd_string = encode_text($ussd_cmd);
    }
	return sprintf 'AT+CUSD=%s,"%s",%s', $result_code_presentation, $ussd_string, $encoding;
}

########################################################################
# Function: hex_to_string
# Args:     String consisting of hex values
# Returns:  String containing the given values
sub hex_to_string {
	return pack ("H*", $_[0]);
}

########################################################################
# Function: string_to_hex
# Args:     String 
# Returns:  Hexstring
sub string_to_hex {
	return uc( unpack( "H*", $_[0] ) );
}

########################################################################
# Function: gsm0338_to_utf8
# Args:     String in GSM 03.38 encoding
# Returns:  String in UTF-8 encoding
sub gsm0338_to_utf8 {
    my $utf8;
    eval {
        $utf8 = decode( 'gsm0338', $_[0] , 1);
    };
    if ( $@ ) {
        print "Konvertierung GSM0338->UTF-8 fehlgeschlagen: $@\n";
        print "Das hätte gar nicht passieren dürfen!\n";
        exit 1;
    }
    return $utf8;
}

########################################################################
# Function: utf8_to_gsm0338
# Args:     String in UTF-8 encoding
# Returns:  String in GSM 03.38 encoding
sub utf8_to_gsm0338 {
    my $gsm0338;
    eval {
        $gsm0338 = encode( 'gsm0338', $_[0] , 1);
    };
    if ( $@ ) {
        print STDERR "Konvertierung UTF-8->GSM0338 fehlgeschlagen: $@\n";
        print STDERR "Bitte das USSD-Kommando pruefen!\n";
        exit 1;
    }
    return $gsm0338;
}

########################################################################
# Function: encode_text
# Args:     String in UTF-8 format
# Returns:  Hexstring containing the above string in GSM 03.38 encoding
sub encode_text {
	my ($text)              = @_;
	my $gsm_text	        = utf8_to_gsm0338( $text );
	my $packed_gsm_string	= gsm_pack( $gsm_text );
	return	            	string_to_hex( $packed_gsm_string );
}

########################################################################
# Function: decode_text
# Args:     A hex string of GSM packed values corresponding to GSM
#           chars.
# Returns:  A human readable version the argument.
sub decode_text {
	my ($hex)    	= @_;
	my $packed_gsm_string	= hex_to_string($hex);
	my $gsm_string	        = gsm_unpack($packed_gsm_string);
	return	            	gsm0338_to_utf8( $gsm_string );
}

########################################################################
# Function: repack_bits
# Args:     $count_bits_in  Number of bits per arg list element
#           $count_bits_out Number of bits per result list element
#           $bit_values_in  String containing $count_bits_in bits per
#                           char
# Returns:  String containing $count_bits_out bits per char. From a "bit
#           stream" point of view, nothing is changed,
#           only the number of bits per char in arg and result string
#           differ!
#
# This function is really only tested packing/unpacking 7 bit values to
# 8 bit values and vice versa. As this function uses bit operators,
# it'll probably work up to a maximum element size of 16 bits (both in
# and out). If you're running on an 64 bit platform, it might even work
# with elements up to 32 bits length. *Those are guesses, as I didn't
# test this!*
sub repack_bits {
    my ($count_bits_in, $count_bits_out, $bit_values_in) = @_;

    my $bit_values_out	= '';
    my $bits_in_buffer	= 0;
    my $bitbuffer		= 0;
    my $bit_mask_out    = 2**$count_bits_out - 1;

    for (my $pos = 0; $pos < length ($bit_values_in); ++$pos) {
        my $in_bits = ord (substr($bit_values_in, $pos, 1));
		# Die neuen Bits soweit linksshiften, wie noch Bits
		# im Buffer sind und mit dem Buffer ORen.
		# Die vorhandenen Bits um x Bits linksshiften
		$bitbuffer = $bitbuffer | ( $in_bits << $bits_in_buffer);
		$bits_in_buffer += $count_bits_in;

		while ( $bits_in_buffer >= $count_bits_out ) {
			# Die letzten y Bits ausspucken
			$bit_values_out .= chr ( $bitbuffer & $bit_mask_out ) ;
			$bitbuffer = $bitbuffer >> $count_bits_out;
			$bits_in_buffer -= $count_bits_out;
		}	
	}
	# Rest im Buffer inkl. Null-Fuellbits ausgeben
	if ($count_bits_in < $count_bits_out && $bits_in_buffer > 0) {
        $bit_values_out .= chr ( $bitbuffer & $bit_mask_out ) ;
	}

	return $bit_values_out;
}

########################################################################
# Function: gsm_unpack
sub gsm_unpack {
	return repack_bits (8,7, $_[0]);
}

########################################################################
# Function: gsm_pack
sub gsm_pack {
	return repack_bits(7, 8, $_[0]);
}

########################################################################
# Function: DEBUG
sub DEBUG {
    if ($debug) {
        print STDERR '[DEBUG] ' . join(' ',@_) . $/ ;
    }
}

########################################################################
__END__

=head1 NAME

gsm_ussd

=head1 SYNOPSYS

 gsm_ussd --help|-h|-?
 gsm_ussd [-m <modem>] [-t <timeout>] [-p <pin>] [-c] [-d] [-l <logfile>] [<ussd-cmd>]

=head1 DESCRIPTION

USSD queries are a feature of GSM nets - or better, of their providers. You
might already know one USSD query, if you possess a prepaid SIM card:
B<*100#> This query, typed as a "telephone number" into your mobile phone,
will show the balance of your account. Other codes are available to
replenish your account, query your own phone number and a lot more.

For further info about USSD queries and this script, please use
"man gsm-ussd".

=head1 AUTHOR

Jochen Gruse, L<mailto:jochen@zum-quadrat.de>
