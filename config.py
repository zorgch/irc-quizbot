import os

# IRC Network to connect to
network = 'irc'
# Port to connect on
port = 6667
# Channel to join (automatically)
chan = 'quiz'
# Nickname of bot
nickname = 'quizhans'
# Username to use when identifying with services (or not)
username = nickname
# Whether to use a password to identify with services or not
password = os.environ.get('NICKSERV_PASSWORD')
# IRC nick names that can control the bot
masters = [nickname, 'barbara']
if os.environ.get('BOTMASTERS'):
    masters = [nick.strip() for nick in os.environ.get('BOTMASTERS').split(',') if nick.strip()]
# How quickly the bot will get hungry (by asking questions or giving hints)
stamina = 12
# Patience the bot has until it gives hints (in seconds, minimum 5)
hintpatience = 20
# Minimum number of players required to start asking questions.
minplayers = 2
# Threshold representing % of total questions to keep as "recently asked questions"
qrecyclethreshold = 80
# High score database file (is automatically created)
hiscoresdb = os.path.join(os.path.dirname(__file__), 'quiz-hiscores.sqlite')
# Keep a player's scores when IRC nick changes.
keepscore = True
# Whether to print 'category - question - answer' to STDOUT
verbose = os.environ.get('VERBOSE', 'False').lower() in ('true', '1', 'yes', 'on')
