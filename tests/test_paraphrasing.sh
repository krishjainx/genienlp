#!/usr/bin/env bash

. ./tests/lib.sh

i=0

# test almond_natural_seq2seq and almond_paraphrase tasks
for model in \
      "sshleifer/bart-tiny-random"; do

  # train
  genienlp train \
    $SHARED_TRAIN_HPARAMS \
    --train_tasks almond_natural_seq2seq \
    --train_batch_tokens 100 \
    --val_batch_size 100 \
    --train_iterations 6 \
    --save $workdir/model_$i \
    --data $SRCDIR/dataset/ \
    --model TransformerSeq2Seq \
    --pretrained_model $model

  # train for 0 iterations
  genienlp train \
  $SHARED_TRAIN_HPARAMS \
  --train_tasks almond_natural_seq2seq \
  --train_batch_tokens 100 \
  --val_batch_size 100 \
  --train_iterations 0 \
  --save $workdir/model_$i \
  --data $SRCDIR/dataset/ \
  --model TransformerSeq2Seq \
  --override_question "" \
  --pretrained_model $model

  # greedy prediction
  genienlp predict \
    --tasks almond_paraphrase \
    --evaluate test \
    --path $workdir/model_$i \
    --overwrite \
    --eval_dir $workdir/model_$i/eval_results/ \
    --data $SRCDIR/dataset/ \
    --embeddings $EMBEDDING_DIR \
    --extra_metrics rouge1 rougeL

  # use as a HuggingFace model directly in genienlp predict
  genienlp predict \
    --tasks almond_paraphrase \
    --evaluate test \
    --path $model \
    --overwrite \
    --eval_dir $workdir/model_$i/hf_results/ \
    --data $SRCDIR/dataset/ \
    --embeddings $EMBEDDING_DIR \
    --pred_languages en \
    --model TransformerSeq2Seq \
    --min_output_length 1 \
    --max_output_length 150 \
    --val_batch_size 100 \
    --is_hf_model

  # check if result file exists
  if test ! -f $workdir/model_$i/eval_results/test/almond_paraphrase.tsv || \
     test ! -f $workdir/model_$i/eval_results/test/almond_paraphrase.results.json || \
     test ! -f $workdir/model_$i/hf_results/test/almond_paraphrase.tsv || \
     test ! -f $workdir/model_$i/hf_results/test/almond_paraphrase.results.json; then
    echo "File not found!"
    exit 1
  fi

  # check if eval_results matche hf_results
  diff -u $workdir/model_$i/hf_results/test/almond_paraphrase.tsv $workdir/model_$i/eval_results/test/almond_paraphrase.tsv

  rm -rf $workdir/model_$i
  i=$((i+1))
done


# tests for the old paraphrasing code
cp -r $SRCDIR/dataset/paraphrasing/ $workdir/paraphrasing/
for model in "sshleifer/bart-tiny-random" ; do

  if [[ $model == *gpt2* ]] ; then
    model_type="gpt2"
  elif [[ $model == */bart* ]] ; then
    model_type="bart"
  fi

  # use a pre-trained model to paraphrase almond's train set
  genienlp run-paraphrase \
    --model_name_or_path $model \
    --length 15 \
    --temperature 0.4 \
    --repetition_penalty 1.0 \
    --num_samples 4 \
    --input_file $SRCDIR/dataset/almond/train.tsv \
    --input_column 1 \
    --output_file $workdir/generated_"$model_type".tsv \
    --task paraphrase

  # check if result file exists
  if test ! -f $workdir/generated_"$model_type".tsv ; then
      echo "File not found!"
      exit 1
  fi
  rm -rf $workdir/generated_"$model_type".tsv
  rm -rf $workdir/"$model_type"

done


# masked paraphrasing tests
cp -r $SRCDIR/dataset/paraphrasing/ $workdir/masked_paraphrasing/

for model in "sshleifer/bart-tiny-random" "sshleifer/tiny-mbart" ; do

  if [[ $model == *mbart* ]] ; then
    model_type="mbart"
  elif [[ $model == *bart* ]] ; then
    model_type="bart"
  fi

  # use a pre-trained model
  genienlp run-paraphrase \
  --model_name_or_path $model \
  --length 15 \
  --temperature 0 \
  --repetition_penalty 1.0 \
  --num_samples 1 \
  --batch_size 3 \
  --input_file $workdir/masked_paraphrasing/dev.tsv \
  --input_column 0 \
  --gold_column 1 \
  --output_file $workdir/generated_"$model_type".tsv  \
  --skip_heuristics \
  --task paraphrase \
  --infill_text \
  --num_text_spans 1 \
  --src_lang en \
  --tgt_lang en

  # create input file for sts filtering
  paste <(cut -f1-2 $workdir/masked_paraphrasing/dev.tsv) <(cut -f2 $workdir/generated_"$model_type".tsv) <(cut -f3 $workdir/masked_paraphrasing/dev.tsv) > $workdir/sts_input_"$model_type".tsv

  # calculate sts score for paraphrases
  genienlp sts-calculate-scores \
    --input_file $workdir/sts_input_"$model_type".tsv \
    --output_file $workdir/sts_output_score_"$model_type".tsv

  # filter paraphrases based on sts score
  genienlp sts-filter \
    --input_file $workdir/sts_output_score_"$model_type".tsv \
    --output_file $workdir/sts_output_"$model_type".tsv \
    --filtering_metric constant \
    --filtering_threshold 0.98


  if test ! -f $workdir/generated_"$model_type".tsv || test ! -f $workdir/sts_output_"$model_type".tsv ; then
      echo "File not found!"
      exit 1
  fi

done

rm -fr $workdir
rm -rf $SRCDIR/torch-shm-fi
