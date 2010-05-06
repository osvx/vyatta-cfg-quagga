# Author: Robert Bays <robert@vyatta.com>
# Date: 2010
# Description: interface between Vyatta templates and Quagga vtysh

# **** License ****
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
# 
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
# 
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2010 Vyatta, Inc.
# All Rights Reserved.
# **** End License ****

package Vyatta::Quagga::Config;

use strict;
use warnings;

use lib "/opt/vyatta/share/perl5/";
use Vyatta::Config;

my $_DEBUG = 0;
my %_vtysh;
my %_vtyshdel;
my $_qcomref = '';
my $_qcomdelref = '';
my $_vtyshexe = '/usr/bin/vtysh';

###  Public methods -
# Create the class.  
# input: $1 - level of the Vyatta config tree to start at
#        $2 - hashref to Quagga add/change command templates
#        $3 - hashref to Quagga delete command templates
sub new {
  my $that = shift;
  my $class = ref ($that) || $that;
  my $self = {
    _level  => shift,
    _qcref  => shift,
    _qcdref => shift,
  };

  $_qcomref = $self->{_qcref};
  $_qcomdelref = $self->{_qcdref};

  if (! _qtree($self->{_level}, 'delete')) { return 0; }
  if (! _qtree($self->{_level}, 'set')) { return 0; }

  bless $self, $class;
  return $self;
}

# Set/check debug level 
# input: $1 - debug level
sub setDebugLevel {
  my ($self, $level) = @_;
  if ($level > 0) {
    $_DEBUG = $level; 
    return $level;
  }
  return 0;
}

# reinitialize the vtysh hashes for troublshooting tree
# walk post object creation
sub _reInitialize {
  my ($self) = @_;

  %_vtysh = ();
  %_vtyshdel = ();
  _qtree($self->{_level}, 'delete');
  _qtree($self->{_level}, 'set');
}

# populate an array reference with Quagga commands
sub returnQuaggaCommands {
  my ($self, $arrayref) = @_; 
  my $key;
  my $string;

  foreach $key (sort { $b cmp $a } keys %_vtyshdel) {
    foreach $string (@{$_vtyshdel{$key}}) {
      push @{$arrayref}, "$string";
    }
  }

  foreach $key (sort keys %_vtysh) {
    foreach $string (@{$_vtysh{$key}}) {
      push @{$arrayref}, "$string";
    }
  }

  return 1;
}

# methods to send the commands to Quagga
sub setConfigTree {
  my ($self, $level) = @_;
  if (_setConfigTree($level, 0, 0)) { return 1; }
  return 0;
}

sub setConfigTreeRecursive {
  my ($self, $level) = @_;
  if (_setConfigTree($level, 0, 1)) { return 1; }
  return 0;
}

sub deleteConfigTree {
  my ($self, $level) = @_;
  if (_setConfigTree($level, 1, 0)) { return 1; }
  return 0;
}

sub deleteConfigTreeRecursive {
  my ($self, $level) = @_;
  if (_setConfigTree($level, 1, 1)) { return 1; }
  return 0;
}

### End Public methods -
### Private methods
# traverse the set/delete trees and send commands to quagga
# set traverses from $level in tree top down.  
# delete traverses from bottom up in tree to $level.
# execute commands in tree one at a time.  If there is an error in vtysh,
# fail.  otherwise, remove command from tree on success as we may traverse
# this portion of the tree again otherwise.
# input: $1 - level of the tree to start at
#        $2 - delete bool
#        $3 - recursive bool
# output: none, return failure if needed
sub _setConfigTree {
  my ($level, $delete, $recurse) = @_;

  if ((! defined $level)   ||
      (! defined $delete)  ||
      (! defined $recurse))      { return 0; }

  # default tree is the set vtysh hash
  my $vtyshref = \%_vtysh;
  # default tree walk order is top down
  my $sortfunc = \&cmpf;

  # if this is delete, use delete vtysh hash and walk the tree bottom up
  if ($delete) { 
    $vtyshref = \%_vtyshdel; 
    $sortfunc = \&cmpb;
  }

  if ($_DEBUG >= 3) { print "DEBUG: _setConfigTree - enter - level: $level\tdelete: $delete\trecurse: $recurse\n"; }

  my $key;
  my @keys;
  foreach $key (sort $sortfunc keys %$vtyshref) {
    if ($_DEBUG >= 3) { print "DEBUG: _setConfigTree - key $key\n"; }

    if ((($recurse)   && ($key =~ /^$level/)) || ((! $recurse) && ($key =~ /^$level$/))) {
      my ($index, $cmd);
      $index = 0;
      foreach $cmd (@{$vtyshref->{$key}}) {
        if ($_DEBUG >= 2) { print "DEBUG: _setConfigTree - key: $key \t cmd: $cmd\n"; }

        if (! _sendQuaggaCommand("$cmd")) { return 0; }
        # remove this command so we don't hit it again in another Recurse call
        delete ${$vtyshref->{$key}}[$index];
        $index++;
      }
    }
  }

  return 1;
}

# sort subs for _setConfigTree
sub cmpf { $a cmp $b }
sub cmpb { $b cmp $a }

# properly format a Quagga command for vtysh and send to Quagga
# input: $1 - qVarReplaced Quagga Command string
# output: none, return failure if needed
sub _sendQuaggaCommand {
  my ($command) = @_;
  my $section;
  my $args = "$_vtyshexe --noerr -c 'configure terminal' ";

  my @commands = split / ; /, $command;
  foreach $section (@commands) {
    $args .= "-c '$section' ";
  }
  
  if ($_DEBUG >= 2) { print "DEBUG: _sendQuaggaCommand - args prior to system call - $args\n"; }
  # TODO: need to fix this system call.  split into command and args.
  system("$args");
  if ($? != 0) {
    # TODO: note that DEBUG will never happen here with --noerr as an argument.
    # need to fix --noerr.  Also probably need to code a way to conditionally use --noerr.
    if ($_DEBUG) { 
      print "DEBUG: _sendQuaggaCommand - vtysh failure $? - $args\n";
      print "\n";
    }
    return 0;
  }

  return 1;
}

# translate a Vyatta config tree into a Quagga command using %qcom as a template.
# input: $1 - Vyatta config tree string
#        $2 - Quagga command template string
# output: Quagga command suitable for vtysh as defined by %qcom.
sub _qVarReplace {
  my $node = shift;
  my $qcommand = shift;

  if ($_DEBUG >= 2) {
    print "DEBUG: _qVarReplace entry: node - $node\n";
    print "DEBUG: _qVarReplace entry: qcommand - $qcommand\n";
  }
  my @nodes = split /\s/, $node;
  my @qcommands = split /\s/, $qcommand;

  my $result = '';
  my $token;
  # try to replace (#num, ?var) references foreach item in Quagga command template array
  # with their corresponding value in Vyatta command array at (#num) index
  foreach $token (@qcommands) {
    # is this a #var reference? if so translate and append to result
    if ($token =~ s/\#(\d+);*/$1/) {
      $token--;
      $result="$result $nodes[$token]";
    }
    # is this a ?var reference? if so check for existance of the var in Vyatta Config 
    # tree and conditionally append.  append token + value.  These conditional vars 
    # will only work at EOL in template string.
    elsif ($token =~ s/\?(\w+);*/$1/) {
      # TODO: Vyatta::Config needs to be fixed to accept level in constructor
      my $config = new Vyatta::Config;
      $config->setLevel($node);
      my $value = $config->returnValue($token);
      if ($value) { $result = "$result $token $value"; }
      elsif ($config->exists($token)) { $result = "$result $token"; }
    }
    # is this a @var reference? if so, append just the value instead of token + value
    elsif ($token =~ s/\@(\w+);*/$1/) {
      my $config = new Vyatta::Config;
      $config->setLevel($node);
      my $value = $config->returnValue($token);
      if ($value) { $result = "$result $value"; }
    }
    # if not, just append string to result
    else {
      $result = "$result $token";
    }
  }

  # remove leading space characters
  $result =~ s/^\s(.+)/$1/;
  if ($_DEBUG >= 2) {
    print "DEBUG: _qVarReplace exit: result - $result\n";
  }

  return $result;
}

# For given Vyatta config tree string, find a corresponding Quagga command template 
# string as defined in correctly referenced %qcom.  i.e. add or delete %qcom.
# input: $1 - Vyatta config tree string
#        $2 - Quagga command template hash 
# output: %qcom hash key to corresponding Quagga command template string
sub _qCommandFind {
  my $vyattaconfig = shift;
  my $qcom = shift;
  my $token = '';
  my $command = '';

  my @nodes = split /\s+/, $vyattaconfig;

  # append each token in the Vyatta config tree.  sequentially  
  # check if there is a corresponding hash in %qcom.  if not,
  # do same check again replacing the end param with var to see
  # if this is a var replacement
  foreach $token (@nodes) {
    if    (exists $qcom->{$token})            { $command = $token; }
    elsif (exists $qcom->{"$command $token"}) { $command = "$command $token"; }
    elsif (exists $qcom->{"$command var"})    { $command = "$command var"; }
    else { return undef; }
  }

  # return hash key if Quagga command template string is found
  if (defined $qcom->{$command}) { return $command; }
  else { return undef; }
}

# translate the adds/changes in a Vyatta config tree into Quagga vtysh commands.
# recursively walks the tree.  
# input:  $1 - the level of the Vyatta config tree to start at
#         $2 - the action (set|delete)
# output: none - creates the %vtysh that contains the Quagga add commands
sub _qtree {
  my ($level, $action) = @_;
  my @nodes;
  my ($qcom, $vtysh);

  
  # It's ugly that I have to create a new Vyatta config object every time,
  # but something gets messed up on the stack if I don't.  not sure
  # what yet.  would love to reference a global config and just reset Level.
  my $config = new Vyatta::Config;
  $config->setLevel($level);

  # setup references for set or delete action
  if ($action eq 'set') {
    $qcom = $_qcomref;
    $vtysh = \%_vtysh;

    @nodes = $config->listNodes();
  }
  else {
    $qcom = $_qcomdelref;
    $vtysh = \%_vtyshdel;

    @nodes = $config->listDeleted();
  }

  if ($_DEBUG) { print "DEBUG: _qtree - action: $action\tlevel: $level\n"; }

  # traverse the Vyatta config tree and translate to Quagga commands where apropos
  if (@nodes > 0) {
    my $node;
    foreach $node (@nodes) {
      if ($_DEBUG >= 2) { print "DEBUG: _qtree - foreach node loop - node $node\n"; }

      # for set action, need to check that the node was actually changed.  Otherwise
      # we end up re-writing every node to Quagga every commit, which is bad. Mmm' ok?
      if (($action eq 'delete') || ($config->isChanged("$node"))) {
        # is there a Quagga command template?
        # TODO: need to add function reference support to qcom hash for complicated nodes
        my $qcommand = _qCommandFind("$level $node", $qcom);

        # if I found a Quagga command template, then replace any vars
        if ($qcommand) {
          # get the apropos config value so we can use it in the Quagga command template 
          my $val = undef;
          if ($action eq 'set') { $val = $config->returnValue($node); }
          else { $val = $config->returnOrigValue($node); }

          # is this a leaf node?
          if ($val) {
            my $var = _qVarReplace("$level $node $val", $qcom->{$qcommand});
            push @{$vtysh->{"$qcommand"}}, $var;
            if ($_DEBUG) {
              print "DEBUG: _qtree leaf node command: set $level $action $node $val \n\t\t\t\t\t$var\n";
            }
          }
          else {
            my $var = _qVarReplace("$level $node", $qcom->{$qcommand});
            push @{$vtysh->{"$qcommand"}}, $var;
            if ($_DEBUG) {
              print "DEBUG: _qtree node command: set $level $action $node \n\t\t\t\t$var\n";
            }
          }
        }
      }
      # recurse to next level in tree
      _qtree("$level $node", 'delete');
      _qtree("$level $node", 'set');
    }
  }

  return 1;
}

return 1;