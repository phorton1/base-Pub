#--------------------------------------------------
# Pub::googleTranslate.pm
#--------------------------------------------------
# Uses a separate database to maintain a cache of the translations.
#

package Pub::google::Translate;
use strict;
use warnings;
use threads;
use threads::shared;
use WWW::Google::Translate;
use Pub::Utils;



my $dbg_tl = 0;



BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (
		translateToSpanish
    );
};


my $wgt;



sub init_translate
{
	my $api_key = getTextFile("/dat/private/base_pub_google_api_key.txt");
	display($dbg_tl,0,"init_translate($api_key)");

	$wgt = WWW::Google::Translate->new( {
		key 			=> $api_key,
        default_source  => 'en',
        default_target  => 'es',
		model       	=> 'nmt',
        format     		=> 'text',
        prettyprint 	=> 1,
		cache_file      => "$temp_dir/translate-cache.dat" });

	return $wgt;
}




sub translateToSpanish
	# accepts \n delimited lines of text which will be cached individually
	# fields cannot contain tabs.
{
	my ($text) = @_;
	my $num_lines = split(/\n/,$text);
	init_translate() if !$wgt;

	display($dbg_tl,0,"translateToSpanish() $num_lines lines ".length($text)." bytes\n".
			"ORIGINAL_TEXT\n$text");

	return error("wgt not initialized") if !$wgt;
	my $response = $wgt->translate({ q => $text });
	return error("no response in translateToSpanish")
		if !$response;
	return error("no data in translateToSpanish")
		if !$response->{data} || !$response->{data}->{translations};
	my $trans = shift @{$response->{data}->{translations}};
	my $trans_text = $trans->{translatedText};
	return error("empty translateToSpanish($text)") if !$trans_text;
	my $new_lines = split(/\n/,$trans_text);

	display($dbg_tl,0,"translated $new_lines lines ".length($trans_text)." bytes\n".
			"TRANSLATED_TEXT\n$trans_text");

	return error("translated lines($new_lines) != original($num_lines)\n".
		"ORIGINAL_TEXT:\n$text\nTRANSLATED:\n$trans_text\n")
		if $new_lines != $num_lines;

	return $trans_text;
}


#----------------------------
# test main
#----------------------------

if (0)
{
	my $text = translateToSpanish(
		"Starter Motor, for Perkins 4236M (TAD Part #STA-15?), Freshly Rebuilt\n".
		"Exhaust Elbow, Generator, new\n" );
}



1;
