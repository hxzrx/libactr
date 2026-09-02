This directory contains a module which reintroduces the learning of the Sji
values from experience instead of being based on just the current contents of
declarative memory.

The details of the calculation can be found on the slides in the
Anderson_ACT-R-2020-workshop.pdf with these files.  However, there are a few
changes to that description that have been made to the mechanism used in the
current module:

 - Uses P(Cj|Ni)/P(Cj|~Ni) instead of the approximation P(Ni|Cj)/P(Ni).
 That makes the Sji = log [(F(Ni&Cj)/F(Ni))/(F(~Ni&Cj)/F(~Ni))] not
 counting the new parameters for priors described below.

 - Instead of only the imaginal buffer, it applies to all buffers that have
 a non-zero activation spread at model definition time.  Any changes to the
 buffer spread paramters after the model is defined will not affect how this
 module operates with respect to those buffers i.e. if it was on but set to
 zero it's still going to be considered a source and if it was zero but set
 to non-zero it isn't going to be considered a source.  When handling 
 multiple source buffers, if multiple source buffers are simultaneously
 cleared it will result in them not being associated with each others'
 contents.  This is done for ease of implementation at this point because 
 there are potential ordering issues in such a situation (and that order 
 isn't completely in the modeler's control or guaranteed to be consistent).
 If associating the contents of multiple simultaneously cleared source 
 buffers is found to be needed, the module will be updated to handle that.

 - Instead of a single parameter for a prior value that gets added to all 
 of the F values, use a prior probability and a weight, which if they are
 called p and w respectively results in this equation for Sji:
 
 Sji = log [((F(Ni&Cj) + pw)/(F(Ni) + w)) /((F(~Ni&Cj) + pw)/(F(~Ni) + w))]


--------------------------------------------------------------------------------

To use this module in a model the associative-learning.lisp module code needs
to be loaded, and the easy way to do that is to add this after the call to
clear-all in the model file:

(require-extra "associative-learning")

To enable the new mechanism in a model the :eal parameter must be set to the
decay value (recommended .5).  The :al-prior-p and :al-prior-w parameters can
be set to provide the prior probability and weight values shown above.

If the :ol parameter is set to a non-nil value then the optimized learning
equation (as used for base-level learning) will be used in computing the F(x)
values.

Additionally, if the source buffer(s) will be creating new chunks that will
be added to declarative memory (as opposed to always being merged with chunks
that are already in memory) then those buffers must be marked as not using
the reusable buffer chunk performance improvement.  To do that the model
needs to include this command for each such buffer:

(buffer-requires-copies <buffer>)

e.g. (buffer-requires-copies 'imaginal)

If :eal is t and that condition is detected after model difinition it will
print a warning to indicate that.

--------------------------------------------------------------------------------

There are two simulations of the fan experiment similar to the model in unit 5
of the tutorial included in the al-fan-study.lisp and al-fan-history.lisp files.
Those files determine the data based on the activations of the sentence chunks
after the items have been studied (much like the unit 5 model which performs
one retreival of each item).  The al-fan-study version assumes no prior history
with either the probes or target sentences (like the unit 5 model) and
implements the study phase as one initial presentation of each sentence and
then two passes through a drop-out phase which assumes the model always
responds correctly.  The al-fan-history version is set up to allow one to
specify the details of the past histories of the items and some details of 
the study phase.  For both files, that is all performed in code instead of
writing the productions to do the task.  Details can be found in the comments
of those files.

