This directory contains the code to support two extensions to improve the
timing of vocal buffer speak and subvocalize requests and the timing of word
sounds for the audio module.  The primary change is the inclusion of a lookup
table for syllable counts of words.  The other change is the option of 
splitting the string into separate words at spaces and using the timing of 
the individual words plus the timing for one syllable between the words.


To use this extension add this to a model file after the call to clear-all:

(require-extra "syllable-count")

Alternatively, you can directly load the syllable-count.lisp file when there
are no models currently defined.



It adds two new parameters available in a model:

 :use-syllable-table 
    If set to t (the default) then use the syllable count from the dictionary
    instead of just :char-per-syllable to compute the duration of a word if it
    is in the table.
    
 :split-vocal-strings 
    If set to t (the default is nil) then split the text string into separate 
    words at spaces (multiple sequential spaces are considered as a single
    separator).  Then, the duration will be computed using the sum of the 
    syllable counts for each individual word plus one for each word break.


This changes the get-articulation-time function's result which is used by 
those modules to generate the timing. If register-articulation-time was used
to specify a time for a string then that time will still be used, but if not
then the settings of :use-syllable-table and :split-vocal-strings may change
the timing as described above.

The test-syllable-count.lisp file has a function that reports the results of
some strings with different combinations of the new parameters set, and also
shows the results of running the function.


It also adds the functions register-syllable-count, get-syllable-count, and
remove-syllable-count which are available remotely as "register-syllable-count",
"get-syllable-count", and "remove-syllable-count" respectively.

 register-syllable-count takes two parameters:
   word - a string which specifies a word (which is not case sensitive)
   syllables - an integer >= 1 indicating how many syllables that word has

 This will add or replace the current setting for that word in the syllable
 lookup table.   The lookup table is a global resource, and not specific to
 any model -- changing it will affect all models (unlike register-articulation-
 time).

 It returns the word if the table was successfully updated or nil if there
 was an invalid parameter provided.

 get-syllable-count takes one parameter:
   word - a string which specifies a word (which is not case sensitive)

 This will return the number of syllables for that word if it is in the lookup
 table or nil if it is not in the table or not a valid word.

 remove-syllable-count takes one parameter:
   word - a string which specifies a word (which is not case sensitive)

 This will remove the setting for that word in the syllable lookup table.
 The lookup table is a global resource, and not specific to any model -- 
 changing it will affect all models (unlike register-articulation-time).

 It returns the word if it was successfully removed from the table or nil
 if there was an invalid parameter provided or the word was not in the table.


The dictionary that was used to get the syllable counts is the CMU Pronouncing
Dictionary available from:

http://www.speech.cs.cmu.edu/cgi-bin/cmudict
 or 
https://github.com/Alexir/CMUdict

The license for that dictionary is in the cmudict_LICENSE.txt file.


The specific dictionary file used was downloaded from:

http://svn.code.sf.net/p/cmusphinx/code/trunk/cmudict/cmudict-0.7b

and is included in the cmudict-0.7b.zip file.

Only the words without symbols in them were used (a total of 117193 words), and
when there was more than one pronunciation the first one was used to determine
the syllable count.  For reference, the code that did that is in the file
parse-cmudict-for-syllables.lisp.