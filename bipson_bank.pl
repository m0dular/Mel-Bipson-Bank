# Mel_Bipson_Bank © Mel Bipson, released under GPLv2.  Based on an original idea by Bipson_Bank

#####
# Table of Contents
# 1. <vars> 	Command line arguments and global variables
# 2. <init> 	Google Drive, bank.txt database, and irc initialization
# 3. <sort>	Sort and write datasets, generate txt and html files 
# 4. <help>	Bot helper functions, e.g. sending gdrive files, opening/closing bets
# 5. <conn>	Irc connection functions, admin and user commands
#####

use warnings;
use strict;
use Getopt::Long;
use POE;
use POE::Component::IRC;
use Data::Dumper;
use IO::File;
use URI;
use Net::Google::Drive::Simple;
use Tie::File;
use LWP::Simple;
use XML::LibXML;
use Math::Round qw(:all);
use feature "switch";

# <vars>
# Command line args. only -u, -c, and -l required
my @listen_channels; # irc channels to listen for bets
my @command_channels; # irc channel to listen for admin commands
my $debugging = 0;
my $gdrive_name;
my $resume_from_file = 0;
my $win_pct = 1;
my $server = 'irc.twitch.tv';
my $port = 443;
my $user;
my $oauth;

if ($#ARGV < 2) {
	print "Usage: perl bipson_bank.pl -u <twitch_user> -c <#command_channel> -l <#channel1,#channel2,...>\nSee README for more options and info";
	die(0);
}
GetOptions (	"u=s"  => \$user,
		"o=s"  =>\$oauth,
		"c=s" => \@command_channels,
		"l=s"   => \@listen_channels,
		"d=i"  => \$debugging,
		"r=i"  => \$resume_from_file,
		"w=f"  => \$win_pct,
		"g=s"  => \$gdrive_name,
		"s=s"  => \$server,
		"p=i"  => \$port)
or die("Error in args, possibly wrong type specified\n");
@listen_channels = split(',', join(',', @listen_channels));

# hashrefs
my $betters = {};
my $new_betters = {};
my $red_betters = {};
my $blue_betters = {};

# File Handlers
my $bank_txt_handle = IO::File->new();
my $html_bank_handle = IO::File->new();
my $bets_txt_handle = IO::File->new();
my $bets_html_handle = IO::File->new();
my $top_100_handle = IO::File->new();
my $tool_bet_handle = IO::File->new();
my $personal_tool_handle = IO::File->new();

my $join_cutoff = 1372636800; # July 1, 2013 in unix time

# betting vars
my @queued_betters;
my @admins = ("mel_bipson_bank", "steven_shagall", "thecreaux", "emp_daylyt", "fawksh0und", "drekerr");
my $betting_open = 0;
my $twitch_connecting = 1;
my $red_player;
my $blue_player;
my $red_total;
my $blue_total;
my $red_odds;
my $blue_odds;
my $red_odds_disp;

# Vars and file ids for use with google drive
my $bets_id;
my $bank_id;
my $html_bank_id;
my $top_id;
my $tool_bet_id;
my $personal_tool_id;
my $dir_id;
my $children;
my $gd;


# <init>
# Object to interface with google drive. See Net::Google::Drive::Simple
unless (not defined $gdrive_name) {
	$gd = Net::Google::Drive::Simple->new();
}

# Get an id for every file in the google drive project specified with -p, skip if none given
unless (not defined $gdrive_name) {
	( $children, $dir_id ) = $gd->children( "/$gdrive_name" );
	for my $child ( @$children ) {
		if ($child->title() eq 'bets.html') {
			$bets_id = $child->id();
		}
		elsif ($child->title() eq 'bank.txt') {
			$bank_id = $child->id();
		}
		elsif ($child->title() eq 'bank.html') {
			$html_bank_id = $child->id();
		}
		elsif ($child->title() eq 'top.html') {
			$top_id = $child->id();
		}
		elsif ($child->title() eq 'tool_bet.html') {
			$tool_bet_id = $child->id();
		}
		elsif ($child->title() eq 'personal_tool.html') {
			$personal_tool_id = $child->id();
		}
	}
}


# If -r is specified, load existing totals from bank.txt, applying the percentage specified in -w
if ($resume_from_file and -s "bank.txt") {
	if ($bank_txt_handle->open("<bank.txt")) {
		while (my $line = <$bank_txt_handle> ) {
			chomp($line);
			my @split = (split / /, $line);
			my $name = $split[1];
			my $total = $split[2];
			my $new_total = int($win_pct * $total);
			$betters -> { $name } -> { 'funds' } = ($new_total);
		}
		$bank_txt_handle->close;
	}
	&send_bank();
}
elsif ($resume_from_file) {
	print "Error! No bank.txt found to resume from.\n";
	die(1);
}

# set up handlers for irc events we care about
my ($irc) = POE::Component::IRC->spawn(debug => $debugging, UseSSL => 0);
POE::Session->create(
		inline_states => {
		_start     => \&bot_start,
		irc_001    => \&on_connect,
		irc_public => \&on_public,
		delayed_close  => \&close,
		},
);

# <sort>
# Sort the hash of betters and write it to bank.txt
sub sort_bank { 
	my $counter = 1;
	my $funds;
	if ( $bank_txt_handle->open(">bank.txt")) {
		foreach  my $name (sort { $betters->{$b}->{'funds'} <=> $betters->{$a}->{'funds'} or $a cmp $b } keys %$betters) {
			$funds = $betters -> { $name } -> { 'funds' };
			print $bank_txt_handle "$counter. $name $funds\n";
			$counter++
		}
		$bank_txt_handle->close;
	}
	else { print "couldn't open bank_txt database\n"; }
}

# A simple html display for current rankings written to bank.html
sub sort_bank_html {
	my $funds;

	if ( $html_bank_handle->open(">bank.html")) {
		print $html_bank_handle <<EOF;
<html>
<body>
<ol type="1" start="1">
EOF
		foreach  my $name (sort { $betters->{$b}->{'funds'} <=> $betters->{$a}->{'funds'} or $a cmp $b } keys %$betters) {
			$funds = $betters -> { $name } -> { 'funds' };
			print $html_bank_handle "<a id=$name><li>$name - $funds</a></li><br>";
		}
		print $html_bank_handle <<EOF;
\n</ol>		
</body>
</html>
EOF
	}
	else { print "couldn't open bank_html database\n";}
	$html_bank_handle->close;
}

# Simple html list of top 100 in the bank written to top.html
sub sort_top_100_html {
	if ($top_100_handle->open(">top.html") ) {
			print $top_100_handle <<EOF;
<html>
<body>
<div class="bank-list row-fluid">
    <div class="col-lg-6">
        <ol type="1" start="1">
EOF
			my $counter = 0;
			my $betters_size = keys(%$betters);
			foreach my $name (sort { $betters->{$b}->{'funds'} <=> $betters->{$a}->{'funds'} or $a cmp $b } keys %$betters) {
				last if $counter == 99;
				if ($counter == 50) { 
					print $top_100_handle <<EOF;
        </ol>
    </div>
    <div class="span6">
        <ol type="1" start="51">
EOF
				}
				my $funds = $betters-> { $name } -> { 'funds' };
				print $top_100_handle "<li>$name - $funds</li>";
				$counter++;
			}
			if ($betters_size < 50) {
				for my $i ($betters_size..49) {
					print $top_100_handle "<li></li>";
				}
			}
			if ($betters_size < 100) {
				for my $i ($betters_size..99) {
					print $top_100_handle "<li></li>";
				}
			}
			print $top_100_handle <<EOF;
        </ol>
    </div>
</div>
</body>
</html>
EOF
			$top_100_handle->close;
		}
		else { print "couldn't open top_100 handle\n"; }
}

# A simple toolbar for each user written to personal_tool.html
sub sort_personal_tool {
	my $funds;
	my $counter = 1;

	if ( $personal_tool_handle->open(">personal_tool.html")) {
		print $personal_tool_handle <<EOF;
<html>
<body>
EOF
		foreach  my $name (sort { $betters->{$b}->{'funds'} <=> $betters->{$a}->{'funds'} or $a cmp $b } keys %$betters) {
			$funds = $betters -> { $name } -> { 'funds' };
      print $personal_tool_handle <<EOF;
		<div class="user" id="$name">
    <div class="name-name">$name</div>
    <div class="name-money">$funds</div>
    <div class="name-position">$counter</div>
</div>
EOF
			$counter++;
		}
	}
	else { print "couldn't open personal_tool database\n"; }
	$personal_tool_handle->close;
}

sub sort_bets { 
	my $funds;
	my $bet;
	my $potential_win;
	my $bet_for = "";
	my $blue_flag = 0;
	$blue_total = 0;
	$red_total = 0;

# Iterate over each set of betters, determining odds and totals
	foreach my $name (keys %$red_betters) {
		$bet_for = $red_betters -> { $name } -> { 'bet_for' };
		$bet = $red_betters -> { $name } -> { 'bet' };
		$funds = $betters -> { $name } -> { 'funds' };
		next if ($bet <= 0 or $bet > $funds or $funds == 0);
		$red_total += $bet;
	}
	foreach my $name (keys %$blue_betters) {
		$bet = $blue_betters -> { $name } -> { 'bet' };
		$funds = $betters -> { $name } -> { 'funds' };
		next if ($bet <= 0 or $bet > $funds or $funds == 0);
		$blue_total += $bet;
	}
	if ($blue_total == 0 ) { $blue_odds = 1; }
	else { $blue_odds = $red_total/$blue_total; }
	if ($red_total == 0 ) { $red_odds = 1; }
	else { $red_odds = $blue_total/$red_total; }
	$red_odds_disp = nearest(.001, $red_odds);

	foreach my $channel (@listen_channels) {
		$irc->call(privmsg => $channel => "Red Total: $red_total Blue Total: $blue_total");
	}

# Iterate over each set of betters in order, writing name, bet, and potential win to bets.txt
	if ($bets_txt_handle->open(">bets.txt")) {
		print $bets_txt_handle "Red\n";
		foreach  my $name (sort { $red_betters->{$b}->{'bet'} <=> $red_betters->{$a}->{'bet'} } keys %$red_betters) {
			$bet = $red_betters -> { $name } -> { 'bet' };
			$funds = $betters -> { $name } -> { 'funds' };
			next if ($bet <= 0 or $bet > $funds or $funds == 0);
			$potential_win = int($bet * $red_odds); 
			$potential_win = 1 if $potential_win == 0;
			$red_betters -> { $name } -> { 'potential_win' } = $potential_win;
			print $bets_txt_handle "$name $bet (+$potential_win)\n";
		}
		print $bets_txt_handle("Blue\n");
		foreach  my $name (sort { $blue_betters->{$b}->{'bet'} <=> $blue_betters->{$a}->{'bet'} } keys %$blue_betters) {
			$bet = $blue_betters -> { $name } -> { 'bet' };
			$funds = $betters -> { $name } -> { 'funds' };
			next if ($bet <= 0 or $bet > $funds or $funds == 0);
			$potential_win = int($bet * $blue_odds); 
			$potential_win = 1 if $potential_win == 0;
			$blue_betters -> { $name } -> { 'potential_win' } = $potential_win;
			print $bets_txt_handle "$name $bet (+$potential_win)\n";
		}
		$bets_txt_handle->close;
	}
	else { print "couldn't open bets_txt database\n"; }
}

# Simple html page with odds and bets, arranged from high to low for red and blue betters
sub sort_bets_html {
	my $funds;
	my $bet;
	my $potential_win;

	if ( $bets_html_handle->open(">bets.html")) {
		print $bets_html_handle <<EOF;
<html>
<body>
<div class="col-lg-5 full-bets-red">
     <strong style="font-size: 18px;">RED</strong> - ($red_total)
     <br>
	  <strong>$red_player</strong>
	  <br>
EOF
		foreach  my $name (sort { $red_betters->{$b}->{'bet'} <=> $red_betters->{$a}->{'bet'} } keys %$red_betters) {
			$bet = $red_betters -> { $name } -> { 'bet' };
			$funds = $betters -> { $name } -> { 'funds' };
			next if ($bet <= 0 or $bet > $funds or $funds == 0);
			$potential_win = $red_betters-> { $name } -> { 'potential_win'};
			print $bets_html_handle <<EOF;
<div class="$name"> $name - $bet ($potential_win) </div>
<br>
EOF
		}

		print $bets_html_handle <<EOF;
    </div>
    <div class="col-lg-2 full-bets-odds">
        <strong>ODDS</strong>
        $red_odds_disp/1
    </div>
    <div class="col-lg-5 full-bets-blue">
     <strong style="font-size: 18px;">BLUE</strong> - ($blue_total)
     <br>
	  <strong>$blue_player</strong>
	  <br>
EOF
		foreach  my $name (sort { $blue_betters->{$b}->{'bet'} <=> $blue_betters->{$a}->{'bet'} } keys %$blue_betters) {
			$bet = $blue_betters -> { $name } -> { 'bet' };
			$funds = $betters -> { $name } -> { 'funds' };
			next if ($bet <= 0 or $bet > $funds or $funds == 0);
			$potential_win = int($bet * $blue_odds); 
			$potential_win = 1 if $potential_win == 0;
			$blue_betters -> { $name } -> { 'potential_win' } = $potential_win;
			print $bets_html_handle <<EOF;
<div class="$name"> $name - $bet ($potential_win) </div>
<br>
EOF
		}
		print $bets_html_handle <<EOF;
    </div>
</body>
</html>
EOF

		$bets_html_handle->close;
	}
	else { print "couldn't open database\n"; }
}

sub sort_tool_bet_html {
	if ($tool_bet_handle->open(">tool_bet.html") ) {
		print $tool_bet_handle <<EOF;
<html>
<body>
<div class="col-lg-5 tool-bets-red"_html>
    <strong>RED</strong> - $red_total
    <br>
    <strong>$red_player</strong>
</div>
<div class="col-lg-2 tool-bets-vs">
    <strong>ODDS: $red_odds_disp</strong>
</div>
<div class="col-lg-5 tool-bets-blue">
    <strong>BLUE</strong> - $blue_total
    <br>
    <strong>$blue_player</strong>
</div>
</html>
</body>
EOF
		$tool_bet_handle->close;
		&send_personal_tool();
	}
}

# <help>
sub send_bets {
	&sort_bets();
# skip sending to google drives if no drive name specified
	unless (not defined $gdrive_name) {
		&sort_bets_html();
		$gd->file_upload ("bets.html", $dir_id, $bets_id);
		system ("mv", "bets.html", "bets.html.$$");
	}
}

sub send_bank {
	&sort_bank();
	unless (not defined $gdrive_name) {
		&sort_bank_html();
		$gd->file_upload ("bank.html", $dir_id, $html_bank_id);
	}
}
sub send_top_100 {
	unless (not defined $gdrive_name) {
		&sort_top_100_html();
		$gd->file_upload ("top.html", $dir_id, $top_id);
	}
}
sub send_tool_bet {
	unless (not defined $gdrive_name) {
		$gd->file_upload ("tool_bet.html", $dir_id, $tool_bet_id);
	}
}
sub send_personal_tool {
	unless (not defined $gdrive_name) {
		$gd->file_upload ("personal_tool.html", $dir_id, $personal_tool_id);
	}
}

sub open_bets {
	foreach my $channel (@listen_channels) {
		$irc->call(privmsg => $channel => "MrDestructoid Bets are open for $red_player(RED) vs $blue_player(BLUE)! MrDestructoid");
	}
	$betting_open = 1;
}

sub close_bets {
	foreach my $channel (@listen_channels) {
		$irc->call(privmsg => $channel => "MrDestructoid Betting is closed! Go to http://gdriv.es/mel_bipson to see your bet! MrDestructoid");
	}
	$poe_kernel->delay(delayed_close => 3);
}

# Method called using delayed_close
sub close {
	$betting_open = 0;
	&send_bets();
##
# Add people who type !add during betting to active betters
##
	if (scalar(@queued_betters) > 0) {
		foreach my $name (@queued_betters) {
			next if (defined $betters -> { $name } -> { 'funds' });
			$betters -> { $name } -> { 'funds' } = 895;
		}
		undef @queued_betters;
		&send_bank();
	}
}

sub bailout {
	if ($betting_open) {
		foreach my $channel (@command_channels) {
			$irc->call(privmsg => $channel => "WARNING: BETTING OPEN, BAILOUT NOT APPLIED\n");
		}
	}
	else {
		my $bailout_amt = $_[0];
		if ($bank_txt_handle->open("<bank.txt")) {
			while (my $line = <$bank_txt_handle> ) {
				chomp($line);
				my @split = (split / /, $line);
				my $name = $split[1];
				my $total = $split[2];
				if ($total != -1 and $total < $bailout_amt) {
					$betters -> { $name } -> { 'funds' } = $bailout_amt;
				}
			}
		&send_bank();
		}
		else { print "couldn't open bank_txt database\n"; }
	}
}

sub dispense_bucks {
	my $color = lc($_[0]);
	if ($color ne 'red' and $color ne 'blue') {
		return;
	}
	if ($color eq 'red') {
		foreach my $channel (@listen_channels) {
			$irc->call(privmsg => $channel => "$red_player(RED) wins! Payouts to RED!");
		}
	}
	else {
		foreach my $channel (@listen_channels) {
			$irc->call(privmsg => $channel => "$blue_player(BLUE) wins! Payouts to BLUE!");
		}
	}
	if (-s "bank.txt" ) {
		system("cp", "bank.txt", "bank.txt.bkp$$");
	}
	my ($cur_bet, $bet_for, $cur_funds, $new_total);

	foreach my $name (keys %$red_betters) {
		$bet_for = 'red';
		$cur_bet = $red_betters-> { $name } -> { 'bet' };
		$cur_funds = $betters -> { $name } -> { 'funds' };
		next if $cur_bet <= 0 or $cur_bet > $cur_funds or $cur_funds <= 0; # skip this better if he bet 0, bet more than his total funds, or has no funds

		if ($bet_for eq $color) {
			$new_total = $cur_funds + $red_betters -> { $name } -> { 'potential_win' };
		}
		else {
			$new_total = $cur_funds - $cur_bet;
		}
		$betters -> { $name } -> { 'funds' } = $new_total;
	}
	foreach my $name (keys %$blue_betters) {
		$bet_for = 'blue';
		$cur_bet = $blue_betters-> { $name } -> { 'bet' };
		$cur_funds = $betters -> { $name } -> { 'funds' };
		next if $cur_bet <= 0 or $cur_bet > $cur_funds or $cur_funds <= 0;

		if ($bet_for eq $color) {
			$new_total = $cur_funds + $blue_betters -> { $name } -> { 'potential_win' };
		}
		else {
			$new_total = $cur_funds - $cur_bet;
		}
		$betters -> { $name } -> { 'funds' } = $new_total;
	}
	undef $red_betters;
	undef $blue_betters;
	

	&send_bank();
	&send_top_100();
}

# <conn>
# connect and register for all events
sub bot_start {
	$irc->yield('register', 'all');
	$irc->yield(
			connect => {
			Password => $oauth,
			Nick     => $user,
			Username => $user,
			Ircname  => $user,
			Server   => $server,
			Port     => $port,
			});
}


sub on_connect {
	foreach my $channel (@listen_channels) {
		$irc->call(join => $channel);
	}
	foreach my $channel (@command_channels) {
		$irc->call(join => $channel);
	}
}

# parse messages in the channel
# sometimes you get a trailing space, so put \s* at the end of everything
sub on_public {
	my ($kernel, $who, $where, $msg) = @_[KERNEL, ARG0, ARG1, ARG2];
	my $nick = lc((split /!/, $who)[0]);
	if (not ($nick ~~ @admins) and not defined $betters -> { $nick } ) {
		$_ = $msg;
		return unless m/^!add\s*$/;
	}

	# look for admin commands
	if ($nick ~~ @admins) {
		given ($msg) {
			when (/^!open\s+\w+\s+\w+\s*$/i) {
				$red_player = (split / /, $_)[1];
				$blue_player = (split / /, $_)[2];
				&open_bets();
			}
			when (/^!close.*$/i) { 
				&close_bets(); 
			}
			when (/^!win\s+\w+\s*$/i) {
				my $color = (split / /, $_)[1];
	         &dispense_bucks($color);
			}
			when (/^!betmsg\s*$/i) {
				foreach my $channel (@listen_channels) {
					$irc->call(privmsg => $channel => "MrDestructoid REMINDER: Bets are open for $red_player(RED) vs $blue_player(BLUE)! MrDestructoid");
				}
			}
			when (/^!cancel\s*$/i) {
				if ($betting_open) {
					$betting_open = 0;
				}
				foreach my $channel (@listen_channels) {
					$irc->call(privmsg => $channel => "MrDestructoid Bets are CANCELED!!! MrDestructoid");
				}
				undef $red_betters;
				undef $blue_betters;
			}
			when (/^!bailout\s+\d+\s*$/i) {
				my $bailout = (split / /, $_)[1];
				&bailout($bailout);
			}
		}
	}

	# look for user commands
	if ($betting_open) {
		my $bet;
		given ($msg) {
			when (/^!betred\s+\d+\s*$/i) {
				$bet = (split / /, $msg)[1];
				$red_betters -> { $nick } -> { 'bet' } = $bet;
				if (exists $blue_betters -> { $nick} ) {
					delete $blue_betters -> { $nick };
				}
			}
			when (/^!betblue\s+\d+\s*$/i) {
				$bet = (split / /, $msg)[1];
				$blue_betters -> { $nick } -> { 'bet' } = $bet;
				if (exists $red_betters -> { $nick} ) {
					delete $red_betters -> { $nick };
				}
			}
			when (/^!bet\w+\s+\w+\s*$/i) {
				my $arg0 = lc((split / /, $msg)[0]);
				my $cmd = lc((split / /, $msg)[1]);
				if ($cmd eq 'all') {
					my $max_bet = $betters -> { $nick } -> { 'funds' };
					if ($arg0 =~ /red/) {
						$red_betters -> { $nick } -> { 'bet' } = $max_bet;
						if (exists $blue_betters -> { $nick} ) {
							delete $blue_betters -> { $nick };
						}
					}
					elsif ($arg0 =~ /blue/) {
						if (exists $red_betters -> { $nick} ) {
							delete $red_betters -> { $nick };
						}
						$blue_betters -> { $nick } -> { 'bet' } = $max_bet;
					}
				}
				elsif ($cmd eq 'any') {
					my $max_bet = $betters -> { $nick } -> { 'funds' };
					my $rand = int(rand($max_bet));
					$rand = 1 if $rand == 0;
					if ($arg0 =~ /red/) {
						if (exists $blue_betters -> { $nick} ) {
							delete $blue_betters -> { $nick };
						}
						$red_betters -> { $nick } -> { 'bet' } = $rand;
					}
					elsif ($arg0 =~ /blue/) {
						if (exists $red_betters -> { $nick} ) {
							delete $red_betters -> { $nick };
						}
						$blue_betters -> { $nick } -> { 'bet' } = $rand;
					}
				}
			}
			when (/^!add\s*$/i) {
			return if ($nick =~ /new_account_for_bets/i);
			push @queued_betters, $nick;
			}
		}
	}
	else {
		given ($msg) {
			when (/^!add\s*$/i) {
##
# Parse the user's page for their metadata, 
# only add to the bank if account is older than
# the cutoff date to prevent making new accounts
# this page has changed, commented out for now
##
			return if (defined $betters -> { $nick } -> { 'funds' });
#			my $user_xml = get ("http://twitch.tv/meta/$nick.xml");
#			my $parser = XML::LibXML->new();
#			my $date = $parser->parse_string($user_xml)->findnodes('/meta/created_on')->to_literal->value;
#			if (($join_cutoff - $date) >= 0) { $betters -> { $nick } -> { 'funds' } = 895; }
#			else { $betters -> { $nick } -> { 'funds' } = -1; }
			$betters -> { $nick } -> { 'funds' } = 895;
			&send_bank();
			}
			when (/^!give\s+.+\s+\d+\s*$/i) {
				my $give_to = (split / /, $msg)[1];
				my $give_amount = (split / /, $msg)[2];
				return if not defined $betters -> { $give_to } or $give_amount <= 0 or $give_amount > $betters -> { $nick } -> { 'funds' };
				my $funds_from = $betters -> { $nick } -> { 'funds' };
				my $funds_to = $betters -> { $give_to } -> { 'funds' };
				$betters -> { $nick } -> { 'funds' } = $funds_from - $give_amount;
				$betters -> { $give_to } -> { 'funds' } = $funds_to + $give_amount;
				&send_bank();
			}
		}
	}
}

$poe_kernel->run();
exit 0;
