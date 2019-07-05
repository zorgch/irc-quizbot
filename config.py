# IRC Network to connect to
network = 'irc.freenode.net'
# Port to connect on
port = 6667
# Channel to join (automatically)
chan = 'bot_test'
# Nickname of bot
nickname = 'my_bot'
# Username to use when identifying with services (or not)
username = nickname
# Whether to use a password to identify with services or not
password = False
# IRC nick names that can control the bot
masters = [nickname, 'my_nickname']
# How quickly the bot will get hungry (by asking questions or giving hints)
stamina = 6
# Patience the bot has until it gives hints (in seconds, minimum 5)
hintpatience = 10
# Minimum number of players required to start asking questions.
minplayers = 2
# Threshold representing % of total questions to keep as "recently asked questions"
qrecyclethreshold = 20
# High score database file (is automatically created)
hiscoresdb = 'hiscores.sqlite'
# Keep a player's scores when IRC nick changes.
keepscore = True
# Whether to print 'category - question - answer' to STDOUT
verbose = True
