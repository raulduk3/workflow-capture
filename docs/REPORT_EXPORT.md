# Report Export

Use this command to regenerate the insights PDF with improved wrapping:

```
pandoc insights_2026-02-24.md -o insights_2026-02-24.pdf -V geometry:margin=0.5in -V fontsize=10pt -V longtable=true --pdf-engine=xelatex -H build/pandoc-wrap-header.tex
```

Notes:
- The LaTeX header at build/pandoc-wrap-header.tex tunes table spacing and wrapping.
- Adjust the source and output filenames as needed for newer reports.
