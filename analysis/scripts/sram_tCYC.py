import csv
import matplotlib.pyplot as plt

# Read data from CSV file
csv_file = "/home/barak/project-B/sram_tCYC.csv"

dpram_total = []
dpram_tcyc = []
spram_total = []
spram_tcyc = []
all_data = []  # Store all data for finding smallest tCYC

with open(csv_file, "r") as csvfile:
    reader = csv.reader(csvfile)
    header = next(reader)  # Skip header row
    
    for row in reader:
        if not row or len(row) < 5:
            continue  # Skip empty or incomplete rows
        mem_type = row[0].lower()  # Convert to lowercase for comparison
        total = int(row[3])
        tcyc = float(row[4])
        
        # Store all data
        all_data.append((mem_type, int(row[1]), int(row[2]), total, tcyc))
        
        if mem_type in ['dpram', 'dp']:
            dpram_total.append(total)
            dpram_tcyc.append(tcyc)
        elif mem_type in ['spram', 'sp']:
            spram_total.append(total)
            spram_tcyc.append(tcyc)

# Create detailed scatter plot
plt.figure(figsize=(14, 10))

# Plot scatter points with larger size and edge colors
plt.scatter(dpram_total, dpram_tcyc, alpha=0.8, color='red', label='DPRAM/DP', s=80, edgecolors='darkred', linewidth=0.5)
plt.scatter(spram_total, spram_tcyc, alpha=0.8, color='blue', label='SPRAM/SP', s=80, edgecolors='darkblue', linewidth=0.5)

# Enhanced formatting
plt.xlabel('TOTAL (bits)', fontsize=14, fontweight='bold')
plt.ylabel('tCYC (ns)', fontsize=14, fontweight='bold')
plt.title('SRAM Data: TOTAL vs tCYC Analysis', fontsize=16, fontweight='bold', pad=20)
plt.legend(fontsize=12, frameon=True, shadow=True)
plt.grid(True, alpha=0.4, linestyle='--')

# Add minor ticks for more detail
plt.minorticks_on()
plt.grid(True, which='minor', alpha=0.2, linestyle=':')

# Set axis formatting
plt.ticklabel_format(style='scientific', axis='x', scilimits=(0,0))
plt.xticks(fontsize=12)
plt.yticks(fontsize=12)

# Improve layout
plt.tight_layout()
plt.savefig("sram_total_vs_tcyc.png", dpi=300, bbox_inches='tight')

# Find and print 5 SRAMs with smallest tCYC
sorted_data = sorted(all_data, key=lambda x: x[4])  # Sort by tCYC
print("\n5 SRAMs with smallest tCYC:")
print("TYPE\tLEN\tWID\tTOTAL\ttCYC (ns)")
print("-" * 45)
for i in range(min(5, len(sorted_data))):
    data = sorted_data[i]
    print(f"{data[0]}\t{data[1]}\t{data[2]}\t{data[3]}\t{data[4]}")

print(f"\ntCYC vs TOTAL graph has been saved as sram_total_vs_tcyc.png")
print("Graph saved successfully - script completed!")



