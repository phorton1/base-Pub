#!/usr/bin/perl
#--------------------------------------------------------
# ProcessBody.pm
#--------------------------------------------------------
# SCOPING ISSUE
#
# What I would like:
#
#     Any variables visible in the scope of the caller should
#     be available as substitution variables.
#
# What exists:
#
#     Process body accepts a record $rec and an optional $this
#     parameter for <$$rec{blah}> or <&$this->function()> calls,
#     and allows for the shorthand {blah} notation against $rec.
#     Otherwise, processBody can only see it's own globals and
#     those from My:Utils (in scope at the call to eval()).
#
# So, on the web, we pass in $client as $rec, and for
# many cases can use the {blah} syntax or replace existing
# $$client{} with $$rec().  But all other global variables
# refernced by the web (or anyone else for that matter) must
# be explicitly :: prefixed (i.e. $webSessionUtils::spanish)


package Pub::ProcessBody;
use strict;
use warnings;
use Pub::Utils;
use Pub::Prefs;
	# So get_pref can be called easily from templates

my $dbg_pb = 2;

BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (
        processBody
        processBodyFile
		processBodyMulti
    );
}



sub processBodyFileMulti
	# process a multi-part template from a file
    #
    # A multi-part template expects a $rec that contans an
    #     arrayed {recs} member.
    # everything up to the BODY is processed once against
    #     the main rec and the <body> tag is presented
    # the BODY tag must start, and be on it's own line
    #     and must end with </body> on it's own line
    # the BODY will be processed once for each record in {recs}
	#
    # By convention, the processor adds a _rec_num field to the $recs
    #    so that a page break can be triggered when _rec_num != 0
    # The user must have the margins and stuff setup correctly
    #    for IE print to work ...
{
    my ($filename,$main_rec,$this) = @_;
	display($dbg_pb,0,"processBodyFileMulti($filename) called");

	my $in_body = getTextFile($filename);
	if (!$in_body)
    {
        error("No body in $filename");
        return;
    }
	my @lines = split(/\n/,$in_body);

	my $part = 0;
	my $header_part = '';
	my $body_part = '';
	my $footer_part = '';

	for my $line (@lines)
	{
		if ($line =~ /^<body/)
		{
			$header_part .= $line."\n";
			$part = 1;
		}
		elsif ($line =~ /<\/body/)
		{
			$footer_part = $line."\n";
			$part = 2;
		}
		elsif ($part == 2)
		{
			$footer_part .= $line."\n";
		}
		elsif ($part == 1)
		{
			$body_part .= $line."\n";
		}
		else
		{
			$header_part .= $line."\n";
		}
	}

	my $body = processBody($header_part,$main_rec,$this,$filename);

	my $rec_num = 0;
	for my $rec (@{$main_rec->{recs}})
	{
		$rec->{_rec_num} = $rec_num++;
		$body .= processBody($body_part,$rec,$this,$filename);
	}
	$body .= $footer_part;
	return $body;
}




sub processBodyFile
{
    my ($filename,$rec,$this) = @_;
	display($dbg_pb,0,"processBodyFile($filename) called");
	my $body = getTextFile($filename);
	if (!$body)
    {
        error("No body in $filename");
        return;
    }
	my $result = processBody($body,$rec,$this,$filename);
	display($dbg_pb,0,"processBodyFile() returning ".length($result)." bytes");
	return $result;

}



sub processBody
    # Tokens consist of things in squgily or angle brackets:
    #
    #    <include filename>
    #    <if expression>
    #    <elsif expresion>
    #    <else>
    #    <endif>
    #    <for $variable (list)>
    #    <next>
    #    <last>
    #    <end_for>
    #
    #    <$variable_expression>
    #        things starting with $ are evaulated as is
    #    <&function_expression>
    #        things starting with & are evaulagted without the &
    #    <(assignment_statement)>
    #        things starting with ( are evaluated but return no text
    #
    # The squiggly bracket ones exist for backwards
    # compatability and brevity, and act on the record
    # passed into processBody:
    #
    #    {field_name}
    #    {if|if_not|if_null|if_exists|if_lt0|if_gt0 fieldname}
    #    {else}
    #    {endif}
    #
    # The rest of the discussion is about angle bracket items.
    # All but the last two must be on a line by
    # themselves. Substitution expressions are evaulated
    # within the line.
    #
    # Client can refer to $rec or any global variables
    # declared with "our" or any function in scope.
    #
    # Larger signs '>' can be used if they are preceded by
    # a space, and the routine knows the arrow operator (->)
    # and the SQL not equals operator (<>) and they can be
    # used in expressions.
    #
    # <$variable_expressions> are passed unchanged to eval,
    # <&function_expressions> are passed without the leading &
    #
    #  <&uc('foo')>
    #
    # CARE MUST BE TAKEN. Use of this routine can change
    # variables in the program, so be careful, especially
    # with variables in the My::ProcessBody lexical path,
	# like $body, $in_body, $rec, $if_level, and so on.
    #
    # The for statement, and possibly other statements,
    # create package level variables that can be long lived
    # so some care must be taken to not overuse the space
    # or make assumptions about the undefined value of things.
{
    my ($in_body,$rec,$this,$dbg_filename) = @_;
    my @body_lines = split(/\n/,$in_body);

	$dbg_filename ||= 'body';

    display($dbg_pb,0,"processBody() called with ".length($in_body)." bytes == ".scalar(@body_lines)." lines");

    my $body = "";
    my @if_value;
    my $if_level = 0;

    my %file_included;
    my $include_level = 0;
    my @line_nums = (0);
    my @include_names = ($dbg_filename);
    my @line_buffers = (\@body_lines);

    my $for_level = 0;
    my @for_stuff;

    while (1)
    {
        my $line = undef;
        my $line_num;
        my $include_file;
        while (!defined($line) && $include_level>=0)
        {
            my $lines = $line_buffers[$include_level];
            $line_num = $line_nums[$include_level];
            $include_file = $include_names[$include_level];
            if ($line_num < @$lines)
            {
                $line = $$lines[$line_num++];
                $line_nums[$include_level] = $line_num;
            }
            else
            {
                $include_level--;
            }
        }
        last if ($include_level < 0);

        # see if the line is included at this point
		# condition will be set to zero if any parent
		# is -1 (satisfied) or 0 (false).

        my $condition = 1;
        my $level = $if_level;
        while ($level > 0)
        {
            $condition = 0 if ($if_value[--$level] != 1);
        }

        # if-then-else processing
        # these items must exist on lines by themselves
        # if_value is tri-state ...
        #    1 = including stuff
        #    0 = not including stuff waiting for else
        #   -1 = not including stuff, condition satisfied

        if ($line =~ /{(if|if_not|if_null|if_exists|if_lt0|if_gt0)\s+(.*?)}/)
        {
            my $what = $1;
            my $expr = $2;
            my $value = -1;

            # don't process the expression if the line is not included

            if ($condition)
            {
                my $val = $rec ? $$rec{$expr} : "";
                $val = "" if (!defined($val));
                $val = 0 if ($val eq "" && ($what eq 'if' || $what eq 'if_not'));

                $value =
                    ($what eq 'if_exists') ? ($val ne '' ? 1 : 0) :
                    ($what eq 'if_null')   ? ($val eq '' ? 1 : 0) :
                    ($what eq 'if_not')    ? ($val == 0  ? 1 : 0) :
                    ($what eq 'if_lt0')    ? ($val < 0  ? 1 : 0) :
                    ($what eq 'if_gt0')    ? ($val > 0  ? 1 : 0) :
                    # ($val ? 1 : 0);
                    # tried to use the above,
					# needed below for client statemetns 2014-01-31
					($val !=0 ? 1 : 0);
            }

            display($dbg_pb,1+$include_level+$if_level,"\{$what($expr)}  value=$value level=$if_level");
            $if_value[$if_level++] = $value;
            next;
        }
        elsif ($line =~ /<(if|elsif|elseif)\s+(.*?[^<\-\s]+?)>/)
        {
            my $what = $1;
            my $expr = $2;
            my $value = -1;

            display($dbg_pb,1+$include_level+$if_level,"prodessing $what($expr) level=$level condition=$condition");

			# condition is 0 if any parent condition is either 0 (false)
			# or -1 (unsatisfied), which determines if the 'if' expression
			# should be evaluated. So the 'if' is only evaluated if the
			# $condition is 1.

			# On the other hand, an elseif has already had the level bumped
			# and the 'if' processed. So we look at the immediate parent
			# condition, and only evaluate the elsif expression if the
			# parent is 0 (false).

            if (($what eq 'if' && $condition) ||
                ($what ne 'if' && $if_level && !$if_value[$if_level-1]))
            {
                no strict 'vars';
                no strict 'refs';
                $value = eval("# line $line_num \"$include_file\"\n".$expr) ? 1 : 0;
                use strict 'vars';
                use strict 'refs';

                display($dbg_pb,2+$include_level+$if_level,"eval($expr)  value=$value");

                my $eval_error = $@;
                error($eval_error) if ($eval_error);
            }

			# for if's we bump the level and set the value

            if ($what eq 'if')
            {
                display($dbg_pb,1+$include_level+$if_level,"$what($expr)  value=$value level=$if_level");
                $if_value[$if_level++] = $value;
            }
            elsif (!$if_level)
            {
                error("elsif without if at $include_file($line_num)");
            }

			# for elseifs, we set the parent condition and do not bump the level

            else # old: if (!$if_value[$if_level-1])     # else if (use value if previous state was 'false')
            {
                $if_value[$if_level-1] = $value;  # ==0 ? 1 : -1;
                display($dbg_pb,$include_level+$if_level,"$what($expr)  value=$value level=$if_level");
            }

			#old:
			#else    # skip it if previous state was handled
            #{
            #    $if_value[$if_level-1] = -1;
            #    display($dbg_pb,$include_level+$if_level,"skipping elseif($expr) level=$if_level value=-1");
            #}

			next;
        }
        elsif ($line =~ /<endif>|{endif}/)
        {
            display($dbg_pb,$include_level+$if_level,"endif level=$if_level");
            if (!$if_level)
            {
                error("endif without if at $include_file($line_num)");
            }
            else
            {
                $if_level--;
            }
            next;
        }
        elsif ($line =~ /<else>|{else}/)
        {
            if (!$if_level)
            {
                error("else without if at $include_file($line_num)");
            }
            else
            {
                my $value = $if_value[$if_level-1];
                $value = ($value == 0) ? 1 :
                         ($value == 1) ? 0 :
                         $value;

                display($dbg_pb,$include_level+$if_level,"else level=$if_level value=$value");
                $if_value[$if_level-1] = $value;
            }
            next;
        }

        # loop processing
        # treat a 'for' as an 'if' with a condition
        # of getting the initial value from the array

        if ($line =~ /<for\s+\$(\w+)\s+(.*?[^<\-\s]+?)>/)
        {
            my ($symbol,$expr) = ($1,$2);
            my ($array,$start_line) = (undef,0);
            display($dbg_pb,$include_level+$if_level+1,"<for \$$symbol $expr>");

            # don't start the loop unles this line is included

            if ($condition)
            {
                # evaluate the array expression with error checking
                # pass file ane line number in ...

                no strict 'vars';
                no strict 'refs';
                $array = [eval("# line $line_num \"$include_file\"\n".$expr)];
                use strict 'vars';
                use strict 'refs';

                display($dbg_pb,$include_level+$if_level+1,"array=$array len=".scalar(@$array));

                my $eval_error = $@;
                error($eval_error) if ($eval_error);
                # for my $i (@$array) { print "array[$i]=$$array[$i]\n"; }

                # set start_line if we are to continue, and
                # pull the 0th element off the list

                $start_line = !$eval_error && @$array ? $line_num : 0;

                # set the loop control variable

                my $val = shift(@$array);
                no strict 'vars';
                no strict 'refs';
                eval("\$$symbol=\$val;");
                use strict 'vars';
                use strict 'refs';

                display($dbg_pb+1,$include_level+$if_level+2,"array=".(defined($array)?$array:'undef'));
                display($dbg_pb+1,$include_level+$if_level+2,"start_line=$start_line");
                display($dbg_pb+1,$include_level+$if_level+2,"val=".(defined($val)?$val:'undef'));
                display($dbg_pb+1,$include_level+$if_level+2,"eval(\$$symbol=$val)");
            }

            # push the for onto the stack

            $for_stuff[$for_level++] = [ $start_line, $symbol, $array, $if_level ];

            # use 'if' conditional processing to include
            # lines, or not, based on initial condition

            my $value = $start_line ? 1 : 0;
            $if_value[$if_level++] = $value;
            next;
        }
        elsif ($line =~ /<for\s+/)
        {
            error("ill formed <for> statement at $include_file($line_num)");
            next;
        }
        elsif ($line =~ /<end_for>/)
        {
            if (!$for_level)
            {
                error("<end_for> without <for> at $include_file($line_num)");
            }
            else
            {
                my ($start_line, $symbol, $array, $for_if_level) = (@{$for_stuff[$for_level-1]});
                $start_line = 0 if (!$array || !@$array || $if_value[$for_if_level] == -1);
                display($dbg_pb,$include_level+$if_level,"<end_for>");
                display($dbg_pb+1,$include_level+$if_level+1,"start_line=$start_line");

                if (!$start_line)     # end of loop
                {
                    $for_level--;
                    $if_level--;
                }
                else # another iteration
                {
                    my $val = shift @$array;
                    display($dbg_pb+1,$include_level+$if_level+1,"val=".(defined($val)?$val:'undef'));

                    no strict 'vars';
                    no strict 'refs';
                    eval("\$$symbol=\$val");
                    use strict 'vars';
                    use strict 'refs';

                    $line_nums[$include_level] = $start_line;
                    $if_value[$for_if_level] = 1;
                }
            }
            next;
        }

        # we needed to process the above lines, even if "not included"
        # but that's it ... drop the line now if it's not included.

        next if (!$condition);

        # process next/last if they are in view

        if ($line =~ /<(next|last)>/)
        {
            my $what = $1;
            if (!$for_level)
            {
                error("<$what> without <for> at $include_file($line_num)");
            }
            else
            {
                # stop executing any more code in the for loop
                # and stop the for loop entirely for 'last'

                display($dbg_pb,$include_level+$if_level,"<$what>");
                my ($start_line, $symbol, $array, $for_if_level) = (@{$for_stuff[$for_level-1]});
                $if_value[$for_if_level] = ($what eq 'last' ? -1 : 0);
            }
            next;
        }

        # process include files

        if ($line =~ /<include\s+(.*)>/)
        {
            my $filename = $1;
            if ($file_included{$filename})
            {
                error("Include file loop - already loaded $filename at $include_file($line_num)");
                next;
            }

			# PRH TODO ... include files should be relative to main file

            if (!open INCF,"<$filename")
            {
                error("Could not include $filename at $include_file($line_num)");
                next;
            }
            display($dbg_pb,1+$include_level+$if_level,"including $filename");
            my @lines = <INCF>;
            close INCF;

            chomp @lines;
            $include_level++;
            $line_nums[$include_level] = 0;
            $line_buffers[$include_level] = \@lines;
            $include_names[$include_level] = $filename;
            next;
        }

        # do angle bracket expression substitutions

        while ($line =~ s/<((\(|\$|\&).*?[^<\-\s]+?)>/###HERE###/s)
        {
            my $expr = $1;
            my $what = $2;
            $expr =~ s/^\&// if ($what eq '&');

            no strict 'vars';
            no strict 'refs';
            my $val = eval( "# line $line_num \"$include_file\"\n".$expr );
            use strict 'vars';
            use strict 'refs';

            my $eval_error = $@;
            error($eval_error) if ($eval_error);
            $val = "" if (!defined($val));
            $val = '' if ($what eq '(');
            $line =~ s/###HERE###/$val/;
			my $showval = substr($val,0,60);
			$showval =~ s/\n/ /g;
            display(_clip $dbg_pb,1+$include_level+$if_level,"substituting '$expr' with '$showval'");
        }

        # do squigly bracket expression substitutions

        while ($line =~ s/{((&|\w).*?)}/###HERE###/)
        {
            my $what = $2;
            my $expr = $1;
            my $val;

			# allow a parent to trigger function evaluation

            if ($what eq '&' || $expr=~/\(/)
            {
                $expr =~ s/^&//;

                no strict 'vars';
                no strict 'refs';
                $val = eval($expr);
                use strict 'vars';
                use strict 'refs';

            }
            else
            {
                $val = $rec ? $$rec{$expr} : "";
            }
            $val = "" if (!defined($val));
            $line =~ s/###HERE###/$val/;
            display(_clip $dbg_pb,1+$include_level+$if_level,"substituting '$expr' with '$val'");
        }

        $body .= $line."\n";
    }

    if ($for_level)
    {
        error("missing <end_for> at EOF (for_level=$for_level)");
    }
    elsif ($if_level)
    {
        error("missing <end_if> at EOF (if_level=$if_level)");
    }

    display($dbg_pb,0,"processBody() returning ".length($body)." bytes");
    return $body;

}   # processBody


1;
