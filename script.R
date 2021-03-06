# Section 3: Data processing, exploratory analysis and visualization

# Import required libraries/packages

package_list = c("dplyr", "ggplot2", "tibble", 
                 "reshape2", "reactable", "ggpubr", "rstatix",
                 "parallel", "ggrepel", "tidyr", "stringr", 
                 "dendsort", "reactablefmtr", "circlize",
                 "BiocManager")

bioc_packages = c("DESeq2", "fgsea", "ComplexHeatmap")

verify_packages <- lapply(package_list, FUN = function(x) {
  if (!require(x, character.only = TRUE)) {
    install.packages(x, dependencies = TRUE)
    library(x, character.only = TRUE)
  }
}
)

verify_packages_bioc <- lapply(bioc_packages, FUN = function(x) {
  if (!require(x, character.only = TRUE)) {
    BiocManager::install(x, dependencies = TRUE)
    library(x, character.only = TRUE)
  }
}
)

# Create an output directory for images/tables

if(!dir.exists("output")){
  dir.create("output")
}

# Start off by reading data into R from the provided CSV and view the general structure of the data.

dat <- read.csv("gene_count_matrix.csv")

# Next, save the provided biomarker list as a new variable.

biomarker_list <- read.csv("biomarkers.csv", header = FALSE, col.names = "genes")
biomarker_list <- biomarker_list$genes

# Choosing to work with gene symbols here instead of gene IDs - construct a dataframe with genes as rows and samples as columns.

mat <- dat %>% dplyr::select(-GeneID) %>% column_to_rownames("GeneSymbol")

# Remove all genes with zero counts across all samples

mat <- mat %>% mutate(s = rowSums(across(.cols = where(is.numeric)))) %>% filter(s > 0) %>% dplyr::select(-s)

# Constructing a simple metadata dataframe with just two columns - sample name encoded as "smpl" 
# and sample type (disease or control) encoded as "smpl_type" - samples prefixed with an "**A**" 
# are the disease group, and those with a "**K**" are the control group.

meta.data <- data.frame(smpl = colnames(mat)) %>% 
  mutate(smpl_type = factor(ifelse(substr(smpl, 1, 1) == "A", "disease", "control"), levels = c("control", "disease"))) %>%
  column_to_rownames("smpl")

# Initialize a DESeq2 object to use its median-of-ratios normalization technique 
# (calculates the geometric mean for each gene across samples, and divides each 
# sample by the median of these ratios across all genes - thus helping correct for 
# library size as well as for library composition).

dds <- DESeqDataSetFromMatrix(countData = mat, colData = meta.data, design = ~ smpl_type)

# Perform DESeq2 median-of-ratios normalization on dataset - first calculate size factors.

dds <- estimateSizeFactors(dds)

# Next, get the normalized count matrix back from DESeq2.

norm_counts <- counts(dds, normalized = TRUE)

# Some quick data wrangling to convert this normalized count matrix to a long format dataframe and 
# then merging the raw and normalized counts into one dataframe. 

norm_counts <- merge(meta.data %>% 
                       rownames_to_column("smpl") %>% 
                       dplyr::select(smpl, smpl_type),
                     data.frame(norm_counts) %>% 
                       rownames_to_column("gene") %>% 
                       melt(id.vars = "gene") %>% 
                       dplyr::rename(smpl = variable, value.norm = value))

unnorm_counts <- merge(meta.data %>% 
                         rownames_to_column("smpl") %>% 
                         dplyr::select(smpl, smpl_type),
                       data.frame(mat) %>% 
                         rownames_to_column("gene") %>% 
                         melt(id.vars = "gene") %>% 
                         dplyr::rename(smpl = variable, value.raw = value))


final_mat <- merge(norm_counts, unnorm_counts)

# Calculate summary statistics on the raw and normalized counts of the genes pre-defined as 
# biomarkers (blue = lowest, orange = highest in each column)

mapping_names_labels <- 
  data.frame(names = c("smpl_type", "gene", "raw.max", "raw.min", "raw.mean", "raw.median", "norm.max", "norm.min", "norm.mean", "norm.median"),
             transformed = c("Sample Type", "Gene", "Max. value (raw)", "Min. value (raw)", "Mean value (raw)", "Median value (raw)", 
                             "Max. value (norm.)", "Min. value (norm.)", "Mean value (norm.)", "Median value (norm.)"))
tbl <- final_mat %>% filter(gene %in% biomarker_list) %>% 
  group_by(gene, smpl_type) %>%
  mutate(raw.max = max(value.raw),
         raw.min = min(value.raw),
         raw.mean = mean(value.raw),
         raw.median = median(value.raw),
         norm.max = max(value.norm),
         norm.min = min(value.norm),
         norm.mean = mean(value.norm),
         norm.median = median(value.norm)) %>% 
  dplyr::select(-smpl, -value.norm, -value.raw) %>% ungroup %>% unique %>%
  mutate(across(where(is.numeric), .fns = ~ round(., 2)))

colnames(tbl) <-  mapping_names_labels$transformed[match(colnames(tbl), mapping_names_labels$names)]

tbl_out <- reactable(
  tbl %>% group_by(Gene) %>% arrange(Gene, `Sample Type`) %>%
    relocate(Gene),
  columns = list(
    Gene = colDef(
      style = JS("function(rinfo, col, s) {
        const first = s.sorted[0]
        if (!first || first.id === 'Gene') {
          const prev = s.pageRows[rinfo.viewIndex - 1]
          if (prev && rinfo.row['Gene'] === prev['Gene']) {
            return {visibility: 'hidden' }
          }
          else{
          return {fontStyle: 'italic', fontSize: 18}
          }
        }
      }")
    )
  ), height = 600, width = 1080)

tbl_out <- tbl_out %>% add_title("Summary statistics - biomarkers", align = "center")

save_reactable_test(tbl_out, "output/1_summary_stats.png")

# Next, plot individual boxplots for each gene - standardize data (convert to z-scores) to convert 
# all genes to a comparable scale for ease of plotting

biomarker_expr <- norm_counts %>% 
  filter(gene %in% biomarker_list) %>%
  group_by(gene) %>%
  mutate(z = (value.norm - mean(value.norm))/sd(value.norm)) %>%
  ungroup

# Perform two-sample t-tests to test for differences in scaled expression, and correct for 
# multiple testing (using the Benjamini-Hochberg method)

biomarker_stats <- biomarker_expr %>%
  group_by(gene) %>% 
  t_test(z ~ smpl_type) %>% 
  adjust_pvalue(p.col = "p", method = "BH") %>%
  add_significance(p.col = "p.adj") %>% 
  add_y_position()

# As an alternative represenation of the data above - plot a heatmap of putative biomarkers 
# across the samples (z-scores) - clustering does not appear to be strongly driven by disease state.

boxplot_plt <- biomarker_expr %>% ggplot() + 
  geom_boxplot(aes(x = smpl_type, 
                   y = z, 
                   fill = smpl_type), outlier.shape = NA) + 
  facet_wrap(~ gene) + geom_jitter(aes(x = smpl_type, 
                                       y = z, 
                                       col = smpl_type, alpha = .8)) +
  theme_bw() + 
  theme(legend.position = "none", 
        axis.title.x = element_text(size = 12),
        axis.title.y = element_text(size = 12),
        axis.text.x = element_text(size = 12),
        axis.text.y = element_text(size = 12),
        strip.text = element_text(size = 12),
        strip.background = element_blank(),
        panel.grid.major = element_blank(),
        panel.grid.minor = element_blank(),
        plot.title = element_text(hjust = 0.5)) + 
  xlab("") + ylab("Gene expression (z-score)") + 
  scale_fill_manual(values = c("steelblue", "salmon")) +
  scale_color_manual(values = c("steelblue", "salmon")) + 
  stat_pvalue_manual(biomarker_stats, label = "p.adj", color = "grey40", size = 5) + 
  scale_y_continuous(expand = expansion(mult = c(0.05, 0.2))) + 
  ggtitle("Biomarker expression across disease state")

ggsave(filename = "output/2_biomarker_boxplots.png", plot = boxplot_plt, device = "png", height = 5, width = 5, units = "in")

# As an alternative represenation of the data above - plot a heatmap of putative biomarkers across 
# the samples (z-scores) - clustering does not appear to be strongly driven by disease state.

mat <- norm_counts %>% 
  pivot_wider(names_from = "gene", values_from = "value.norm")
mat <- mat %>% 
  dplyr::select(-smpl) %>% 
  dplyr::select(smpl_type, unlist(biomarker_list))

mat <- biomarker_expr %>% 
  dplyr::select(-value.norm) %>% 
  pivot_wider(names_from = "gene", values_from = "z") %>% 
  dplyr::select(-smpl)

col_dend = dendsort(hclust(dist((mat[, -1]))))
col_fun = colorRamp2(c(-4, 0, 4), 
                     c("#4D9221", "#F7F7F7", "#C51B7D"))

ha <- HeatmapAnnotation(state = mat$smpl_type, 
                        name = "State", 
                        col = list(state = 
                                     c("disease" = "salmon", 
                                       "control" = "steelblue")))

png("output/3_biomarker_heatmap.png",width=8,height=5,units="in",res=1200)
Heatmap(t(mat[,-1]), top_annotation = ha, name = "Z-score", cluster_columns = col_dend, col = col_fun, row_title = "Biomarkers",
        column_title = "Samples")
dev.off()

# Can the expression of any of the biomarker genes classify disease samples from controls? 
# This can be evaluated by looking at whether the normalized expression of any gene can 
# accurately segregate the disease samples from the control samples.

res.pred.disease <- data.frame()

all_samples <- norm_counts %>% dplyr::select(smpl, smpl_type) %>% distinct

p_samples <- all_samples %>% filter(smpl_type == "disease") %>% nrow

n_samples <- all_samples %>% filter(smpl_type == "control") %>% nrow

x <- lapply(X = seq_along(biomarker_list), FUN = function(i){
  
  gene.sig <- biomarker_list[[i]]
  
  #Calculate sum of ranks of "positives" (disease samples)
  sum_ranks <- 
    norm_counts %>% 
    filter(gene %in% gene.sig) %>%
    mutate(rank = rank(value.norm)) %>%
    filter(smpl_type == "disease") %>%
    dplyr::select(rank) %>% "[["(1) %>%
    sum
  
  #Calculate AUROC
  curr.auroc.test <- sum_ranks / (p_samples * n_samples) - (p_samples + 1) / (2 * n_samples)
  
  #Append gene-wise AUROCs to dataframe
  res.pred.disease <<- 
    rbind(res.pred.disease, data.frame(n_genes = i, gene = gene.sig, roc = curr.auroc.test, mode = "test",
                                       clust = i))
})

# The AUROC is evaluating the ability of each individual gene to rank disease samples above 
# control samples, however since we have only 5 disease and 5 control samples, it is important 
# to evaluate the null distribution of AUROCs by random permutation (the null expectation) of 
# the ordering of samples (since only a small number of AUROC values are possible). 
# This task also lends itself rather well to multi-core processing as each permutation 
# can be calculated individually. 

smpls.emp.dist.auroc <- data.frame(smpl = unique(norm_counts$smpl)) %>% 
  mutate(smpl_type = factor(ifelse(substr(smpl, 1, 1) == "A", "disease", "control"), levels = c("control", "disease")))

p_samples <- smpls.emp.dist.auroc %>% filter(smpl_type == "disease") %>% nrow
n_samples <- smpls.emp.dist.auroc %>% filter(smpl_type == "control") %>% nrow

null.dist <- 
  mclapply(seq(from = 1, to = 5000, by = 1), FUN = function(i){
    set.seed(i)
    curr.smpl <- smpls.emp.dist.auroc %>% mutate(rank = sample(seq_along(smpl), nrow(.)))
    sum_ranks <- 
      curr.smpl %>%
      filter(smpl_type == "disease") %>%
      dplyr::select(rank) %>% "[["(1) %>%
      sum
    curr.auroc.test <- sum_ranks / (p_samples * n_samples) - (p_samples + 1) / (2 * n_samples)
  }, mc.cores = 25)

emp.null <- data.frame(auroc = unlist(null.dist))

upper_bound <- emp.null %>% top_frac(n = 0.025, wt = auroc) %>% min %>% round(2)

lower_bound <- emp.null %>% top_frac(n = -0.025, wt = auroc) %>% max %>% round(2)

roc_plt <- res.pred.disease %>%
  ggplot() + aes(x = gene, y = roc, fill = gene) + 
  geom_bar(stat = 'identity') + 
  scale_y_continuous(breaks = 
                       sort(c(seq(0, 1, length.out = 5), upper_bound, lower_bound))) + 
  theme(legend.position = "none", 
        axis.text.x = element_text(angle = 90)) + 
  theme_classic() + 
  geom_hline(yintercept = 0.5, linetype = "dotted") +
  geom_hline(yintercept = upper_bound, linetype = "dashed", color = "steelblue") +
  geom_hline(yintercept = lower_bound, linetype = "dashed", color = "steelblue") +
  geom_text(aes(x = 5, y = upper_bound, label = "\ntop 2.5%"), 
            size = 3.5, color = "steelblue") + 
  geom_text(aes(x = 5, y = lower_bound, label = "\nbottom 2.5%"), 
            size = 3.5, color = "steelblue") + 
  theme(legend.position = "none", 
        axis.title.x = element_text(size = 12),
        axis.title.y = element_text(size = 12),
        axis.text.x = element_text(size = 12, angle = 90),
        axis.text.y = element_text(size = 12),
        strip.text = element_text(size = 12),
        strip.background = element_blank(),
        plot.title = element_text(hjust = 0.5)) + 
  ylab("AUROC") + 
  xlab("") +
  ggtitle("Classification of disease samples") +
  scale_fill_brewer(palette = "Set2")

ggsave(filename = "output/4_biomarker_aurocs.png", plot = roc_plt, device = "png", height = 4, width = 6, units = "in")

# Quick additional data exploration - function to calculate PCA and plot graph (adapted slightly from DESeq2)

plotPCA_ <- function (object, intgroup = "condition", ntop = 500, returnData = FALSE, title) 
{
  rv <- rowVars(assay(object))
  select <- order(rv, decreasing = TRUE)[seq_len(min(ntop, 
                                                     length(rv)))]
  pca <- prcomp(t(assay(object)[select, ]))
  percentVar <- pca$sdev^2/sum(pca$sdev^2)
  if (!all(intgroup %in% names(colData(object)))) {
    stop("the argument 'intgroup' should specify columns of colData(dds)")
  }
  intgroup.df <- as.data.frame(colData(object)[, intgroup, 
                                               drop = FALSE])
  group <- if (length(intgroup) > 1) {
    factor(apply(intgroup.df, 1, paste, collapse = ":"))
  }
  else {
    colData(object)[[intgroup]]
  }
  d <- data.frame(PC1 = pca$x[, 1], PC2 = pca$x[, 2], group = group, 
                  intgroup.df, name = colnames(object))
  if (returnData) {
    attr(d, "percentVar") <- percentVar[1:2]
    return(d)
  }
  ggplot(data = d, aes_string(x = "PC1", y = "PC2", color = "group")) + 
    geom_point(size = 3) + xlab(paste0("PC1: ", round(percentVar[1] * 
                                                        100), "% variance")) + ylab(paste0("PC2: ", round(percentVar[2] * 
                                                                                                            100), "% variance")) + ggtitle(title) + 
    theme(plot.title = element_text(hjust = 0.5, size = 15, vjust = 0.1, face = "bold"), 
          axis.title = element_text(size = 15),
          axis.text = element_text(size = 15), legend.text = element_text(size = 12), legend.title = element_text(size = 12)) 
}


# Apply variance-stabilizing transformation to expression matrix

vsd <- vst(dds)

# Principal component analysis on expression matrix does not reveal separation by disease state

pca_plt <- plotPCA_(vsd, intgroup = "smpl_type", title = "Principal Component Analysis - bulk RNA-seq samples") + theme_bw() + 
  theme(panel.grid.major = element_blank(),
        panel.grid.minor = element_blank()) +
  scale_color_manual(name = "Group", breaks = c("control", "disease"), values = c("steelblue", "salmon"), labels = c("control", "disease"))

ggsave(filename = "output/5_dataset_pca.png", plot = pca_plt, device = "png", height = 4, width = 6, units = "in")

# Differential expression testing across disease state (disease vs. control)

dds <- DESeq(dds)

de_results <- results(dds, contrast = c("smpl_type", "disease", "control"))

de_results <- lfcShrink(dds, contrast = c("smpl_type", "disease", "control"), type = "ashr", res = de_results)

de_tbl <- data.frame(de_results) %>% rownames_to_column("gene")

# Volcano plot to display top up- and down-regulated genes in disease state vs controls - uses a threshold of 
# abs(log2FC) > 1.0 and adj. P-value < 0.05 to select genes which are DE. 
# Also, genes which are assigned a NA adj. P value by DESeq2 are excluded 
# (genes which did not pass independent filtering/have outliers as measured by Cook's distance)

`%notin%` <- Negate(`%in%`)
l2fc_thresh = 1.0
padj_thresh = 0.05
  
filt_de_tbl <-
  de_tbl %>% 
  filter(!is.na(padj)) 

# Plot volcano plot as specified above

vol_plt <- rbind(subset(filt_de_tbl, gene %notin% biomarker_list), subset(filt_de_tbl, gene %in% biomarker_list)) %>%
  ggplot() + 
  aes(x = log2FoldChange, y = -log2(padj)) + 
  geom_jitter(aes(color = 
                    case_when((abs(log2FoldChange) > l2fc_thresh & padj < padj_thresh) ~ "1",
                              gene %in% biomarker_list ~ "2",
                              TRUE ~ "3"), 
                  size = 20)) + 
  geom_vline(xintercept = -1 * l2fc_thresh, color = "blue", linetype = "dotted") + 
  geom_vline(xintercept = 1 * l2fc_thresh, color = "blue", linetype = "dotted") + 
  geom_hline(yintercept = -log2(padj_thresh), color = "red", linetype = "dotted") + 
  geom_text_repel(max.overlaps = 20, 
                  aes(x = log2FoldChange, y = -log2(padj), label = gene, size = 20, point.size = NA),
                  data = filt_de_tbl %>% filter(abs(log2FoldChange) > l2fc_thresh & -log2(padj) > -log2(padj_thresh))) + 
  geom_text_repel(max.overlaps = 20, 
                  aes(x = log2FoldChange, y = -log2(padj), label = gene, size = 20, point.size = NA),
                  data = filt_de_tbl %>% filter(gene %in% biomarker_list)) +
  scale_color_manual(name = "Legend", values = c("salmon", "steelblue", "grey"), breaks = c("1", "2", "3"), labels = c("Differentially expressed", "Putative biomarker", "Not DE")) +
  scale_size(guide = "none") +
  ggtitle("Differential expression - disease vs. control") +
  xlab("Log2 (F.C.)") +
  ylab("-Log2 (adj. P)") +
  theme_classic() +
  theme(plot.title = element_text(hjust = 0.5, size = 20, vjust = 0.1), 
        axis.title = element_text(size = 16),
        axis.text = element_text(size = 16),
        strip.text = element_text(size = 16),
        legend.title = element_text(size = 14),
        legend.text = element_text(size = 12))

ggsave(filename = "output/6_volcano_plot.png", plot = vol_plt, device = "png", height = 6, width = 10, units = "in")

# Enrichment analysis is performed in a fashion similar to GSEA 
# (using the Wilcoxon test instead of the Kolmogorov-Smirnov test)
# Load GO terms from MSigDb for enrichment analyses

GO_complete <- fgsea::gmtPathways("genesets/c5.go.v7.2.symbols.gmt")
GO_subset <- list()
x <- lapply(names(GO_complete), function(i){
  GO_subset[[i]] <<- GO_complete[[i]][GO_complete[[i]] %in% filt_de_tbl$gene]
})

# Perform enrichment analyses on full DE table using the Mann-Whitney test - 
# First rank genes based on where they occur in the DE table - next perform 
# a Mann-Whitney test on the ranks of genes which occur in a specific gene set 
# versus genes which do not occur in that particular gene set. This allows for 
# the sensitive detection of subtle shifts in the ranking of genes associated 
# with any gene set, pointing towards changes in functional terms. The functions 
# for performing these analyses are defined below.

# Prep gene list for M-W-style enrichment analysis
prepRankedGeneList <- function(filt_de_tbl){
  l2fc <- filt_de_tbl %>% dplyr::select(log2FoldChange) %>% "[["(1)
  names(l2fc) <- filt_de_tbl %>% dplyr::select(gene) %>% "[["(1)
  rank_l2fc <- rank(l2fc, ties.method = "average")
  return(rank_l2fc)
}


# Mann-Whitney-style enrichment on whole DE table
genesetEnrichment <- 
  function(ranked_list, gene_set_list, max_size_gene_set = 200, min_size_gene_set = 10, fdr_correct = TRUE, 
           fdr_threshold = 0.05, de_tbl = NULL, de_fc_thresh = 1.5, de_padj_thresh = 5e-2, hypothesis = "two.sided"){
    
    
    gene_list <- names(ranked_list)
    
    subset_gene_set_list <- list()
    
    x <- lapply(names(gene_set_list), function(i){
      subset_gene_set_list[[i]] <<- gene_set_list[[i]][gene_set_list[[i]] %in% gene_list]
      })
    
    keep <- lapply(seq_along(subset_gene_set_list),
           function(i){
             ifelse(
               ((length(subset_gene_set_list[[i]]) > min_size_gene_set) & 
                 (length(subset_gene_set_list[[i]]) < max_size_gene_set)), TRUE, FALSE)
           })
    
    filt_gene_set <- subset_gene_set_list[unlist(keep)]
    
    raw <- data.frame()
    
    enrich_res <- mclapply(seq_along(filt_gene_set), function(i){
    
      data.frame(geneset = names(filt_gene_set)[i],
                 n_shared = length(ranked_list[unlist(filt_gene_set[i])]),
                 n_not_shared = length(ranked_list[-c(which(names(ranked_list) %in% unlist(filt_gene_set[i])))]),
                 avg_rank_shared = mean(ranked_list[unlist(filt_gene_set[i])]),
                 avg_rank_not_shared = mean(ranked_list[-c(which(names(ranked_list) %in% unlist(filt_gene_set[i])))]),
                 pval = wilcox.test(ranked_list[unlist(filt_gene_set[i])],
                                    ranked_list[-c(which(names(ranked_list) %in% unlist(filt_gene_set[i])))],
                                    alternative = hypothesis)$p.value)
    }, mc.cores = 25)
  
  raw <- bind_rows(enrich_res) %>% mutate(padj = p.adjust(pval, "BH"))
  return(raw)
}


# Perform the enrichment analysis

enrich <- 
  rbind(genesetEnrichment(ranked_list = prepRankedGeneList(filt_de_tbl), 
                                gene_set_list = GO_subset, max_size_gene_set = 100,
                                hypothesis = "greater") %>% mutate(dir = "up"),
  genesetEnrichment(ranked_list = prepRankedGeneList(filt_de_tbl), 
                                gene_set_list = GO_subset, max_size_gene_set = 100,
                                hypothesis = "less") %>% mutate(dir = "down"))

# Make GO term names look a bit more friendly

go_plot <- enrich
go_plot$geneset <- str_split(go_plot$geneset, "GO_", simplify = TRUE)[, 2]
go_plot$geneset <- str_replace_all(go_plot$geneset, "_", " ")

# Plot enriched GO terms in up-regulated genes (genes in geneset preferentially occur towards the top of the DE table)

enrich_up_plt <- go_plot %>% 
  arrange(padj) %>% 
  filter(dir == "up" & padj <= 0.1) %>%
  head(n = 25) %>%
  ggplot() + 
  aes(x = -log2(padj), y = reorder(geneset, -log2(padj)), size = -log2(padj), col = -log2(padj)) + 
  geom_point(position = position_dodge(width = 0.5)) + 
 
    xlab("-Log2 (adj. P)") + 
    ylab("") + theme_bw() +
    theme(panel.grid = element_blank(), axis.text.y = element_text(size = 10),
          plot.title = element_text(hjust = 1.5, size = 15)) + 
    scale_size_continuous(name = "-Log2 (adj. P)") + scale_color_continuous(name = "-Log2 (Adj. p)") + 
    ggtitle("Enriched GO terms (up-regulated genes)")

ggsave(filename = "output/7_enrich_up.png", plot = enrich_up_plt, device = "png", height = 7, width = 9, units = "in")

# Plot enriched GO terms in down-regulated genes (genes in geneset preferentially occur towards the bottom of the DE table)

enrich_down_plt <- go_plot %>% 
  arrange(padj) %>% 
  filter(dir == "down" & padj <= 0.1) %>%
  head(n = 25) %>%
  ggplot() + 
  aes(x = -log2(padj), y = reorder(geneset, -log2(padj)), size = -log2(padj), col = -log2(padj)) + 
  geom_point(position = position_dodge(width = 0.5)) + 
 
    xlab("-Log2 (adj. P)") + 
    ylab("") + theme_bw() +
    theme(panel.grid = element_blank(), axis.text.y = element_text(size = 10),
          plot.title = element_text(hjust = 1.5, size = 15)) + 
    scale_size_continuous(name = "-Log2 (adj. P)") + scale_color_continuous(name = "-Log2 (Adj. p)") + 
  ggtitle("Enriched GO terms (down-regulated genes)")

ggsave(filename = "output/8_enrich_down.png", plot = enrich_down_plt, device = "png", height = 7, width = 9, units = "in")


