## Mel Bipson Bank

# Overview
An IRC bot that listens for, manages, and uploads bets. Designed for use with Twitch.tv.  Please see http://gdriv.es/mel_bipson for a simple Google Drives interface for the program's output.

# Setup
To execute this program, you will need a perl environment with CPAN and a few modules.  Please see the includes at the top of the program to see the required modules.

To connect to a twitch account, you will need to use an OAuth token accociated with your account. See http://www.twitchapps.com/tmi/ for how to generate one.  If you want to help run the project using the accounts I've used in the past, contact me and I will give you the OAuth token and access keys you need.

If you want to connect to a group chat on Twitch, there are a couple of extra steps.  You will need to get the exact name of the private chat and the IP address associated with it using the Twitch ChatDepot API. To do this, you will need to generate an OAuth token (see above).  Your Twitch account will need to be joined to the group chat you are looking for.  Then, call the api by going to http://chatdepot.twitch.tv/room_memberships?oauth_token=TOKEN_HERE, where TOKEN_HERE is your OAuth token without the 'oauth:' prefix.  The field with the channel name is 'irc_channel', e.g. mel_bipson_bank_1402348327104, and can be identified by the 'display_name' field associated with it. The IP address you need is contained in the 'servers' field.  Pass the channel name to the program using -c or -l, then specify it's server using -s.  Please note that this is currently a beta feature, and that these group chats run on different IPs than the traditional chat.  Because of this, you will have to connect to chat servers running on this IP, and you may not be able to connect to multiple chat rooms.

If you want to upload files to Google Drives, you will need to set up a Google Drive account and enable the Drive API and Drive SDK for your account.  See https://developers.google.com/drive/web/enable-sdk for more info.  
 
Next, you will need to install and set up Net::Google::Drive::Simple to mangage the API calls to Google Drives.  See the description for https://metacpan.org/pod/Net::Google::Drive::Simple.

# Usage and arguments

Usage: perl bipson_bank.pl -u <twitch_user> -o <oauth_token> -c <#command_channel> -l <#channel1,#channel2,...> -<extra args here>

Arguments:
-u: Twitch username.  Can be a string.  The username that the bot will use to connect to Twitch.
-o: OAuth token.  Can be a string.  The token you will need to connect your user.  Include oauth: in the string, e.g. 'oauth:xxx'
-c: Command_channels  Can be one or more comma-separated irc channels, eg #mel_bipson_bank,#thecreaux.  Used to listen for admin commands and output debug info, # is necessary in string.
-l: Listen_channels   Can be one or more comma-separated irc channels.  Used to listen for user commands and output betting information # is necessary in string.
-d: Debugging flag.  Can be 0 (off) or 1 (on), default to 0.  Used to turn on/off debugging output for the irc object.  Set this if you want to see the irc debugging and messages the bot receives.
-r: Resume from file.  Can be 0 (off) or 1 (on), default to 0.  If turned on, the program looks for and loads an existing bank.txt to the database.
-w: Winning_percent.  Can be a decimal number, default to 1.  When specified in conjuction with -r, this is the percentage modifier applied to existing totals loaded from bank.txt.  For example, with -w .25, everyone loaded from bank.txt would keep 25% of their current total.
-g: Google drive project name.  Can be a string.  Name of the directory under your Google Drive account you want to upload files to. 
-s: Chat server IP address.  Can be a string, default to irc.twitch.tv.  IP address for the chat server the bot will try to connect to.  Change this if you are connecting to a private chat or different irc server.
-p: Port.  Can be a number, default to 443.  Port used to connect to the chat servers.  Change this if you need to use a custom port.

# License

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.


