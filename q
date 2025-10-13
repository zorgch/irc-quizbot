#!/usr/bin/env python3
# -*- coding: utf-8 -*-

# Copyright (C) 2012, 2013  Alexander Berntsen <alexander@plaimi.net>
# Copyright (C) 2012, 2013  Stian Ellingsen <stian@plaimi.net>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

"""Simple quizbot that asks questions and awards points."""

import config
import sqlite3
import importlib

from getpass import getpass
from operator import itemgetter
from random import choice, shuffle
from sys import argv
from time import time

from twisted.words.protocols import irc
from twisted.internet import protocol, reactor
from twisted.python import log

import strings
import questions as q


class Bot(irc.IRCClient):

    """The bot procedures go here."""

    def _get_nickname(self):
        """Sets Bot nick to our chosen nick instead of defaultnick."""
        return self.factory.nickname
    
    def _set_nickname(self, value):
        """Allow Twisted to set the nickname internally."""
        # Twisted sets this during connection, we just ignore it
        # and keep using factory.nickname
        pass
    
    nickname = property(_get_nickname, _set_nickname)

    def connectionMade(self):
        """Overrides CONNECTIONMADE."""
        # Identifies with nick services if password is set.
        if config.password:
            self.password = self.factory.password
            self.username = self.factory.username
        self.quizzers = {}
        self.minplayernum = 2 if config.minplayers is None else config.minplayers
        self.hint_patience = 6 if config.hintpatience is None else config.hintpatience
        self.last_decide = 10
        self.answered = 5
        self.winner = ''
        self.question = ''
        if config.qrecyclethreshold is None:
            self.recently_asked_threshold = ((20*len(q.questions))/100.0)
        else:
            self.recently_asked_threshold = ((config.qrecyclethreshold*len(q.questions))/100.0)
        self.recently_asked = []
        self.db = sqlite3.connect(config.hiscoresdb, isolation_level=None)
        self.dbcur = self.db.cursor()
        try:
            self.dbcur.execute('CREATE TABLE IF NOT EXISTS hiscore (quizzer TEXT unique, wins INTEGER)')
        except self.db.IntegrityError as e:
            log.err(f'sqlite error: {e.args[0]}')
        self.db.commit()
        self.hunger = 0
        self.stamina = 6 if config.stamina is None else config.stamina
        self.complained = False
        irc.IRCClient.connectionMade(self)

    def signedOn(self):
        """Overrides SIGNEDON."""
        self.join(self.factory.channel)
        log.msg(f"signed on as {self.nickname}")

    def joined(self, channel):
        """Overrides JOINED."""
        log.msg(f"joined {channel}")
        self.op(self.nickname)
        # Get all users in the chan.
        self.sendLine("NAMES %s" % self.factory.channel)
        reactor.callLater(5, self.reset)
        reactor.callLater(5, self.decide)

    def userJoined(self, user, channel):
        """Overrides USERJOINED."""
        name = self.clean_nick(user)
        self.add_quizzer(name)
        self.complained = False

    def userLeft(self, user, channel):
        """Overrides USERLEFT."""
        self.del_quizzer(user)

    def userQuit(self, user, channel):
        """Overrides USERQUIT."""
        self.del_quizzer(user)

    def userRenamed(self, oldname, newname):
        """Overrides USERRENAMED."""
        self.del_quizzer(oldname)
        self.add_quizzer(newname)
        # Change quizzer name in DB to keep score.
        if config.keepscore:
            self.dbcur.execute('SELECT * FROM hiscore WHERE quizzer=?',
                                (oldname,))
            row = self.dbcur.fetchone()
            if row is not None:
                self.dbcur.execute('UPDATE hiscore SET quizzer=? WHERE quizzer=?',
                                    (newname, oldname))
                self.db.commit()

    def irc_RPL_NAMREPLY(self, prefix, params):
        """Overrides RPL_NAMEREPLY."""
        # Add all users in the channel to quizzers.
        for i in params[3].split():
            if i != self.nickname:
                self.add_quizzer(i)

    def privmsg(self, user, channel, msg):
        """Overrides PRIVMSG."""
        name = self.clean_nick(user)
        # Check for answers.
        if not self.answered:
            if name not in self.quizzers:
                self.quizzers[name] = 0
            elif self.quizzers[name] is None:
                self.quizzers[name] = 0
            if str(self.answer).lower() in msg.lower():
                self.award(name)
        # Check if it's a command for the bot.
        if msg.startswith('!help'):
            try:
                # !help user
                self.help(msg.split()[1])
            except:
                # !help
                self.help(name)
        elif msg.startswith('!reload'):
            self.reload_questions(name)
        elif msg.startswith('!botsnack'):
            self.feed()
        elif msg.startswith('!op'):
            self.op(name)
        elif msg.startswith('!deop'):
            self.deop(name)
        elif msg.startswith('!score'):
            self.print_score()
        elif msg.startswith('!hiscore'):
            self.print_hiscore()
        # Unknown command.
        elif msg[0] == '!':
            self.msg(self.factory.channel if channel != self.nickname else
                     name, strings.unknowncmd)

    def decide(self):
        """Wait for enough players."""
        numPlayers = len(self.quizzers)
        if numPlayers < self.minplayernum:
            self.msg(self.factory.channel, strings.waiting)
            reactor.callLater(30, self.decide)
            return
        else:
            numPlayers += 1
        if numPlayers >= self.minplayernum:
            """Figure out whether to post a question or a hint."""
            t = time()
            f, dt = ((self.ask, self.answered + 5 - t) if self.answered else
                     (self.hint, self.last_decide + self.hint_patience - t))
            if dt < 0.5:
                f()
                self.last_decide = t
                dt = 5
            reactor.callLater(min(5, dt), self.decide)

    def ask(self):
        """Make bot hungy."""
        self.hunger += 1
        if self.hunger > self.stamina:
            if not self.complained:
                self.msg(self.factory.channel,
                         strings.botsnack)
                self.complained = True
            return
        """Ask a question."""
        # Make sure there have been ten questions in between this question.
        while self.question in self.recently_asked or not self.question:
            cqa = choice(q.questions)
            self.question = cqa[1]
        self.category = cqa[0]
        # Clear recently asked questions when threshold is reached
        if len(self.recently_asked) >= self.recently_asked_threshold:
            self.recently_asked.pop(0)
        self.recently_asked.append(self.question)
        self.answer = cqa[2]
        self.msg(self.factory.channel, strings.question %
                (self.category, self.question))
        if config.verbose:
            log.msg(f'{self.category} - {self.question} - {self.answer}')
        # Make list of hidden parts of the answer.
        self.answer_masks = list(range(len(str(self.answer))))
        # Set how many characters are revealed per hint.
        self.difficulty = max(len(str(self.answer)) // 6, 1)
        if isinstance(self.answer, str):
            # Shuffle them around to reveal random parts of it.
            shuffle(self.answer_masks)
        else:
            # Reveal numbers from left to right.
            self.answer_masks = self.answer_masks[::-1]
        # Number of hints given.
        self.hint_num = 0
        # Time of answer.  0 means no answer yet.
        self.answered = 0

    def hint(self):
        """Give a hint."""
        # Max 5 hints, and don't give hints when the answer is so short.
        if len(str(self.answer)) <= self.hint_num + 1 or self.hint_num >= 5:
            if (len(str(self.answer)) == 1 and self.hint_num == 0):
                self.msg(self.factory.channel, strings.hintone)
                self.hint_num += 1
            else:
                self.fail()
            return
        # Reveal difficulty amount of characters in the answer.
        for i in range(self.difficulty):
            try:
                # If hint is ' ', pop again.
                while self.answer_masks.pop() == ' ':
                    pass
            except:
                pass
        self.answer_hint = ''.join(
            '*' if idx in self.answer_masks and c != ' ' else c for
            idx, c in enumerate(str(self.answer)))
        self.msg(self.factory.channel, strings.hint % self.answer_hint)
        self.hint_num += 1

    def fail(self):
        """Timeout/giveup on answer."""
        self.msg(self.factory.channel, strings.rightanswer % self.answer)
        self.msg(self.factory.channel, strings.wishluck)
        self.answered = time()

    def award(self, awardee):
        """Gives a point to awardee."""
        self.quizzers[awardee] += 1
        self.msg(self.factory.channel, strings.correctanswer %
                (self.answer, awardee))
        if self.quizzers[awardee] == self.target_score:
            self.win(awardee)
        self.hunger = max(0, self.hunger - 1)
        self.answered = time()

    def win(self, winner):
        """Is called when target score is reached."""
        numAnswerers = 0
        quizzersByPoints = sorted(self.quizzers.items(), key=itemgetter(1),
                                  reverse=True)
        for numAnswerers, (quizzer, points) in enumerate(quizzersByPoints):
            if points is None:
                break
        else:
            numAnswerers += 1
        if numAnswerers > 1:
            winner = quizzersByPoints[0][0]
            self.dbcur.execute('SELECT * FROM hiscore WHERE quizzer=?',
                                   (winner,))
            wins = 1
            row = self.dbcur.fetchone()
            if row is not None:
                wins = row[1] + 1
                sql = 'UPDATE hiscore SET wins=? WHERE quizzer=?'
            else:
                sql = 'INSERT INTO hiscore (wins, quizzer) VALUES (?, ?)'
            try:
                self.dbcur.execute(sql, (wins, winner))
            except self.db.IntegrityError as e:
                log.err(f'sqlite error: {e.args[0]}')
            self.db.commit()

        self.winner = winner
        self.msg(self.factory.channel,
                 strings.winner % self.winner)
        self.reset()

    def help(self, user):
        """Message help message to the user."""
        # Prevent spamming to non-quizzers, AKA random Freenode users.
        if user not in self.quizzers:
            return

        self.msg(user, strings.help_channelinfo % self.factory.channel)
        self.msg(user, strings.help_botinfo % self.nickname)

        for msgline in strings.help:
            self.msg(user, msgline)

    def reload_questions(self, user):
        """Reload the question/answer list."""
        if self.is_p(user, self.factory.masters):
            importlib.reload(q)
            self.msg(self.factory.channel, 'reloaded questions.')

    def feed(self):
        """Feed quizbot."""
        self.hunger = 0
        self.complained = False
        self.msg(self.factory.channel, strings.thanks)

    def op(self, user):
        """OP a master."""
        if self.is_p(user, self.factory.masters):
            self.msg('CHANSERV', 'op %s %s' % (self.factory.channel, user))

    def deop(self, user):
        """DEOP a master."""
        if self.is_p(user, self.factory.masters):
            self.msg('CHANSERV', 'deop %s %s' % (self.factory.channel, user))

    def print_score(self):
        """Print the top five quizzers."""
        prev_points = -1
        for i, (quizzer, points) in enumerate(
                sorted(self.quizzers.items(), key=itemgetter(1),
                       reverse=True)[:5], 1):
            if points:
                if points != prev_points:
                    j = i
                self.msg(self.factory.channel, strings.score %
                         (j, quizzer, points))
                prev_points = points

    def print_hiscore(self):
        """Print the top five quizzers of all time."""
        self.dbcur.execute('SELECT * FROM hiscore ORDER by wins DESC LIMIT 5')
        hiscore = self.dbcur.fetchall()
        for i, (quizzer, wins) in enumerate(hiscore):
            self.msg(self.factory.channel, strings.score %
                    (i + 1, quizzer.encode('UTF-8'), wins))

    def set_topic(self):
        self.dbcur.execute('SELECT * FROM hiscore ORDER by wins DESC LIMIT 1')
        alltime = self.dbcur.fetchone()
        if alltime is None:
            alltime = ["no one", 0]
        self.topic(
            self.factory.channel, strings.channeltopic %
                    (self.target_score, self.winner, alltime[0].encode('UTF-8'),
                     alltime[1]))

    def reset(self):
        """Set all quizzers' points to 0 and change topic."""
        for i in self.quizzers:
            self.quizzers[i] = None
        self.target_score = 1 + len(self.quizzers) // 2
        self.set_topic()

    def add_quizzer(self, quizzer):
        """Add quizzer from quizzers."""
        if quizzer == self.nickname or quizzer == '@' + self.nickname:
            return
        if quizzer not in self.quizzers:
            self.quizzers[quizzer] = 0

    def del_quizzer(self, quizzer):
        """Remove quizzer from quizzers."""
        if quizzer == self.nickname or quizzer == '@' + self.nickname:
            return
        if quizzer in self.quizzers:
            del self.quizzers[quizzer]

    def is_p(self, name, role):
        """Check if name is role."""
        try:
            if name in role:
                return True
        except:
            if name == role:
                return True
        if role == self.quizzers:
            return False
        self.msg(self.factory.channel, strings.invalidname % name)
        self.kick(self.factory.channel, name, strings.kickmsg)
        self.del_quizzer(name)
        return False

    def clean_nick(self, nick):
        """Cleans the nick if we get the entire name from IRC."""
        nick = nick.split('!')[0]
        if nick[0] == '~':
            nick = nick.split('~')[1]
        return nick


class BotFactory(protocol.ClientFactory):

    """The bot factory."""

    protocol = Bot

    def __init__(self, channel):
        self.channel = channel
        self.nickname = config.nickname
        self.username = config.username
        if config.password and isinstance(config.password, str):
            self.password = config.password
        elif config.password and config.password is True:
            self.password = getpass('enter password (will not be echoed): ')
        self.masters = config.masters

    def clientConnectionLost(self, connector, reason):
        log.msg(f"connection lost: ({reason})\nreconnecting...")
        connector.connect()

    def clientConnectionFailed(self, connector, reason):
        log.err(f"couldn't connect: {reason}")

if __name__ == "__main__":
    if len(argv) > 1:
        print("""
        edit config.py.

        start program with:
        $ ./q

        if you have set password in config, it will ask for it.
        """)
    else:
        # Initialize logging
        import sys
        log.startLogging(sys.stdout)
        
        reactor.connectTCP(config.network, config.port,
                           BotFactory('#' + config.chan))
        reactor.run()
