use warnings;
use strict;
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

my $channel = "#mel_bipson_bank";
my $poverty_channel = "#thepovertychat";
my $bipson_channel = "#mel_bipson_bank";

#hashrefs
my $betters = {};
my $new_betters = {};
my $red_betters = {};
my $blue_betters = {};

my @queued_betters;

my $database_handle = IO::File->new();
my $html_bank_handle = IO::File->new();
my $betting_handle = IO::File->new();
my $top_handle = IO::File->new();
my $tool_bet_handle = IO::File->new();
my $personal_tool_handle = IO::File->new();

# July 1, 2013 in unix time
my $join_cutoff = 1372636800;
my $betting_open = 0;
my $twitch_connecting = 1;
my $red_player;
my $blue_player;
my $red_total;
my $blue_total;
my $red_odds;
my $blue_odds;

my $bets_id;
my $bank_id;
my $html_bank_id;
my $top_id;
my $tool_bet_id;
my $personal_tool_id;

# object to interface with google drives
# basically copypasta'd this from the docs :D
my $gd = Net::Google::Drive::Simple->new();
my( $children, $dir_id ) = $gd->children( "/bank" );
for my $child ( @$children ) {
#	if ($child->title() eq 'bets.html') {
#		$bets_id = $child->id();
#	}
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

my ($irc) = POE::Component::IRC->spawn(debug => 1, UseSSL => 0);

# Read in current bet database
if (-s "bank.txt") {
	if ($database_handle->open("<bank.txt")) {
		while (my $line = <$database_handle> ) {
			chomp($line);
			my @split = (split / /, $line);
			my $total = $split[2];
			if ($split[1] =~ /new_account_for_bets/i) { $betters -> { $split[1] } -> { 'funds' } = -1; }
# Start with 25% of winnings, otherwise 895
			elsif ($total != -1 and $total > 895) { 
				my $new_total = $total - 895;
				my $asdf = int(.25 * $new_total);
				$betters -> { $split[1] } -> { 'funds' } = ( 895 + $asdf);
			}
			else {
				$betters -> { $split[1] } -> { 'funds' } = 895;
			}
# Bailout or select funds from bank
#			else {
#				if ($total != -1 and $total < 400) {
#					$betters -> { $split[1] } -> { 'funds' } = 400;
#				}
#				else {
##					$betters -> { $split[1] } -> { 'funds' } = $split[2]; 
#					$betters -> { $split[1] } -> { 'funds' } = 895;
#				}
#			}
		}
		$database_handle->close;
	}
	&sort_bank();
	&send_bank();
}

# set up handlers for irc events we care about
POE::Session->create(
		inline_states => {
		_start     => \&bot_start,
		irc_001    => \&on_connect,
		irc_public => \&on_public,
		irc_352    => \&get_names,
		irc_315    => \&got_names,
		delayed_close  => \&close,
		},
);

sub close {
	$betting_open = 0;
	&sort_bets();
	&send_bets();
	if (scalar(@queued_betters) > 0) {
		foreach my $name (@queued_betters) {
			next if (defined $betters -> { $name } -> { 'funds' });
			$betters -> { $name } -> { 'funds' } = 895;
		}
		undef @queued_betters;
		&sort_bank();
		&send_bank();
	}
}

# Sets up the various web pages
sub sort_bank { 
	my $counter = 1;
	my $funds;
	if ( $database_handle->open(">bank.txt") and $html_bank_handle->open(">bank.html") and $personal_tool_handle->open(">personal_tool.html")) {
		print $html_bank_handle <<EOF;
<html>
<body>
<ol type="1" start="1">
EOF
		print $personal_tool_handle <<EOF;
<html>
<body>
EOF
		foreach  my $name (sort { $betters->{$b}->{'funds'} <=> $betters->{$a}->{'funds'} or $a cmp $b } keys %$betters) {
			$funds = $betters -> { $name } -> { 'funds' };
			print $database_handle "$counter. $name $funds\n";
			print $html_bank_handle "<a id=$name><li>$name - $funds</a></li><br>";
			print $personal_tool_handle <<EOF;
<div class="user" id="$name">
    <div class="name-name">$name</div>
    <div class="name-money">$funds</div>
    <div class="name-position">$counter</div>
</div>
EOF
			$counter++;
		}
		print $html_bank_handle <<EOF;
\n</ol>		
</body>
</html>
EOF
		$html_bank_handle->close;
		$database_handle->close;
		$personal_tool_handle->close;
	}
	else { print "couldn't open database\n"; }
}


sub sort_bets { 
	my $funds;
	my $bet;
	my $potential_win;
	my $bet_for = "";
	my $blue_flag = 0;
	my $blue_total = 0;
	my $blue_odds_disp;
	my $red_odds_disp;
	my $red_total = 0;

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
	$blue_odds_disp = nearest(.001, $blue_odds);

#	print "sending totals\n";
	$irc->call(privmsg => $channel => "Red Total: $red_total Blue Total: $blue_total");

	if ( $betting_handle->open(">bets.html")) {
		print $betting_handle <<EOF;
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
			$potential_win = int($bet * $red_odds); 
			$potential_win = 1 if $potential_win == 0;
			$red_betters -> { $name } -> { 'potential_win' } = $potential_win;
			print $betting_handle <<EOF;
<div class="$name"> $name - $bet ($potential_win) </div>
<br>
EOF
		}

		print $betting_handle <<EOF;
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
			print $betting_handle <<EOF;
<div class="$name"> $name - $bet ($potential_win) </div>
<br>
EOF
		}
		print $betting_handle <<EOF;
    </div>
</body>
</html>
EOF

		$betting_handle->close;
	}
	else { print "couldn't open database\n"; }
	
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
		&send_tool_bet();
	}
}

sub send_bets {
	$gd->file_upload ("bets.html", $dir_id, $bets_id);
	system ("mv", "bets.html", "bets.html.$$");
}

sub send_bank {
	$gd->file_upload ("bank.html", $dir_id, $html_bank_id);
}
sub send_top {
	$gd->file_upload ("top.html", $dir_id, $top_id);
}
sub send_tool_bet {
	$gd->file_upload ("tool_bet.html", $dir_id, $tool_bet_id);
}
sub send_personal_tool {
	$gd->file_upload ("personal_tool.html", $dir_id, $personal_tool_id);
}

sub open_bets {
	$irc->call(privmsg => $channel => "MrDestructoid Bets are open for $red_player(RED) vs $blue_player(BLUE)! MrDestructoid");
	$betting_open = 1;
}

sub close_bets {
	$irc->call(privmsg => $channel => "MrDestructoid Betting is closed! Go to gdriv.es/mel_bipson to see your bet! MrDestructoid");
	print "send privmsg\n";
	$poe_kernel->delay(delayed_close => 3);
}

sub dispense_bucks {
	my $color = lc($_[0]);
	if ($color ne 'red' and $color ne 'blue') {
		return;
	}
	if ($color eq 'red') {
		$irc->call(privmsg => $channel => "$red_player(RED) wins! Payouts to RED!");
	}
	else {
		$irc->call(privmsg => $channel => "$blue_player(BLUE) wins! Payouts to BLUE!");
	}
	if (-s "bank.txt" ) {
		system("cp", "bank.txt", "bank.txt.bkp$$");
	}
	my ($cur_bet, $bet_for, $cur_funds, $new_total);
	foreach my $name (keys %$red_betters) {
		$bet_for = 'red';
		$cur_bet = $red_betters-> { $name } -> { 'bet' };
		$cur_funds = $betters -> { $name } -> { 'funds' };
		next if $cur_bet <= 0 or $cur_bet > $cur_funds or $cur_funds <= 0;

		if ($bet_for eq $color) {
			$new_total = $cur_funds + $red_betters -> { $name } -> { 'potential_win' };
#			print "adding $new_total to $cur_funds with blue_odds $blue_odds with red_odds $red_odds for $name\n";
		}
		else {
#			print "minus $cur_bet to $cur_funds for $name\n";
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
#			print "adding $new_total to $cur_funds with blue_odds $blue_odds with red_odds $red_odds for $name\n";
		}
		else {
#			print "minus $cur_bet to $cur_funds for $name\n";
			$new_total = $cur_funds - $cur_bet;
		}
		$betters -> { $name } -> { 'funds' } = $new_total;
	}
	undef $red_betters;
	undef $blue_betters;
	
	if ($top_handle->open(">top.html") ) {
		print "opened top\n";
			print $top_handle <<EOF;
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
					print $top_handle <<EOF;
        </ol>
    </div>
    <div class="span6">
        <ol type="1" start="51">
EOF
				}
				my $funds = $betters-> { $name } -> { 'funds' };
				print $top_handle "<li>$name - $funds</li>";
				$counter++;
			}
			if ($betters_size < 50) {
				for my $i ($betters_size..49) {
					print $top_handle "<li></li>";
				}
			}
			if ($betters_size < 100) {
				for my $i ($betters_size..99) {
					print $top_handle "<li></li>";
				}
			}
			print $top_handle <<EOF;
        </ol>
    </div>
</div>
</body>
</html>
EOF
			$top_handle->close;
			&send_top();
		}
		else { print "couldn't open?\n"; }

	&sort_bank();
	&send_bank();
	&send_personal_tool();
}

sub bot_start {
# connect and register for all events
	$irc->yield('register', 'all');
	$irc->yield(
			connect => {
			Password => 'oauth:nb1sqrwi7h6b8z08sbo3727ge5lvlx5',
			Nick     => 'mel_bipson_bank',
			Username => 'mel_bipson_bank',
			Ircname  => 'mel_bipson_bank',
			Server   => 'irc.twitch.tv',
			Port     => '443',
			});
}

# if we don't get the NAMES command upon joining,
# this won't run and $twitch_connecting will stay 0
sub get_names {
	$twitch_connecting++;
	my ($kernel, $who, $user, @args) = @_[KERNEL, ARG0, ARG1, ARG2];
#	my $names = (split / /, $args)[1];
#	my $better = (split / /, $user)[1];
#	print "better: $better\n";
#	$new_betters -> { $better } -> { 'funds' } = 895 unless $betters -> { $better } -> { 'funds' };
}

# sometimes when you join a channel the list of names is 
# unpopulated, so the NAMES command run by twitch and any
# WHO commands you run are useless. every user joins the 
# channel shorty after in this case, so we just do it 
# until it works.
sub got_names {
	if ($twitch_connecting == 0) {
		print"didn't get names, try it again\n";
		$irc->call(who => $channel);
	}
}

# We don't really care when someone joines the channel,
# only if they add themselves to the bank
#sub on_join {
#	my ($kernel, $who, $where) = @_[KERNEL, ARG0, ARG1];
#	my $user = (split /!/, $who)[0];
#	return if ($twitch_connecting == 0 or $betters -> { $user } -> { 'funds' });
#	$betters -> { $user } -> { 'funds' } = 895;
#	&sort_bank();
#	&send_bank();
#}

sub on_connect {
	$irc->call(join => $channel);
	$irc->call(join => $bipson_channel);
	$irc->call(who => $channel);
}

# parse messages in the channel
# sometimes you get a trailing space, so put \s* at the end of everything
sub on_public {
	my ($kernel, $who, $where, $msg) = @_[KERNEL, ARG0, ARG1, ARG2];
	my $nick = lc((split /!/, $who)[0]);
	if (not defined $betters -> { $nick } ) {
		$_ = $msg;
		return unless m/^!add\s*$/;
	}
#	my $channel = $where->[0];

	# look for bipson commands
	if ($nick eq 'thecreaux' or $nick eq 'emp_daylyt' or $nick eq 'mel_bipson_bank' or $nick eq 'fawksh0und') {
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
				$irc->call(privmsg => $channel => "MrDestructoid REMINDER: Bets are open for $red_player(RED) vs $blue_player(BLUE)! MrDestructoid");
			}
			when (/^!cancel\s*$/i) {
				if ($betting_open) {
					$betting_open = 0;
				}
				$irc->call(privmsg => $channel => "MrDestructoid Bets are CANCELED!!! MrDestructoid");
				undef $red_betters;
				undef $blue_betters;
			}
		}
	}

	# look for bets
	if ($betting_open) {
		my $bet;
		given ($msg) {
			when (/^!betred\s+\d+\s*$/i) {
				$bet = (split / /, $msg)[1];
				$red_betters -> { $nick } -> { 'bet' } = $bet;
				if (exists $blue_betters -> { $nick} ) {
					print "changing bet\n";
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
						print "$nick betall for red\n";
						$red_betters -> { $nick } -> { 'bet' } = $max_bet;
						if (exists $blue_betters -> { $nick} ) {
							delete $blue_betters -> { $nick };
						}
					}
					elsif ($arg0 =~ /blue/) {
						if (exists $red_betters -> { $nick} ) {
							delete $red_betters -> { $nick };
						}
						print "$nick betall for blue\n";
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
# Parse the user's page for their metadata, 
# only add to the bank if account is older than
# the cutoff date to prevent making new accounts
			return if ($nick =~ /new_account_for_bets/i);
			return if (defined $betters -> { $nick } -> { 'funds' });
			my $user_xml = get ("http://twitch.tv/meta/$nick.xml");
			my $parser = XML::LibXML->new();
			my $date = $parser->parse_string($user_xml)->findnodes('/meta/created_on')->to_literal->value;
			if (($join_cutoff - $date) >= 0) { $betters -> { $nick } -> { 'funds' } = 895; }
			else { $betters -> { $nick } -> { 'funds' } = -1; }
			&sort_bank();
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
				&sort_bank();
				&send_bank();
			}
		}
	}
}

$poe_kernel->run();
exit 0;
