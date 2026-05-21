import csv
import math
import matplotlib.pyplot as plt

def find_best_4096_options():
    # Read tCYC data
    tcyc_file = "/home/barak/project-B/sram_tCYC.csv"
    area_file = "/home/barak/project-B/sram_data.csv"
    
    # Target total memory capacity
    target_bits = 32080
    
    # Load all SRAM data
    all_sram_data = []
    
    # Read tCYC data
    with open(tcyc_file, "r") as csvfile:
        reader = csv.reader(csvfile)
        header = next(reader)
        
        for row in reader:
            if not row or len(row) < 5:
                continue
            all_sram_data.append({
                'type': row[0],
                'len': int(row[1]),
                'wid': int(row[2]),
                'total': int(row[3]),
                'tcyc': float(row[4]),
                'area': None
            })
    
    # Match with area data
    with open(area_file, "r") as csvfile:
        reader = csv.reader(csvfile)
        header = next(reader)
        
        for row in reader:
            if not row or len(row) < 6:
                continue
            for sram in all_sram_data:
                if (sram['type'].lower() == row[0].lower() and 
                    sram['len'] == int(row[1]) and 
                    sram['wid'] == int(row[2])):
                    sram['area'] = int(row[5])
                    break
    
    # Filter complete data and show missing matches
    complete_data = [s for s in all_sram_data if s['area'] is not None]
    missing_area = [s for s in all_sram_data if s['area'] is None]
    
    print(f"Total SRAM configurations with tCYC data: {len(all_sram_data)}")
    print(f"Configurations with both tCYC and area data: {len(complete_data)}")
    print(f"Configurations missing area data: {len(missing_area)}")
    
    if missing_area:
        print("\nConfigurations missing area data:")
        for missing in missing_area:
            if missing['type'].lower() in ['sp', 'spram']:
                print(f"  {missing['type']} {missing['len']}x{missing['wid']} = {missing['total']} bits")
    
    # Calculate options for different SRAM configurations
    memory_options = []
    
    for sram in complete_data:
        # Accept units that are at least (target_bits - 50) or smaller (and can be combined)
        if sram['total'] >= target_bits - 50:
            units_needed = 1
        else:
            units_needed = math.ceil(target_bits / sram['total'])
        total_capacity = units_needed * sram['total']
        total_area = units_needed * sram['area']

        # Only include if total_capacity >= target_bits
        if total_capacity >= target_bits:
            memory_options.append({
                'type': sram['type'],
                'len': sram['len'],
                'wid': sram['wid'],
                'unit_size': sram['total'],
                'units_needed': units_needed,
                'total_capacity': total_capacity,
                'waste_bits': total_capacity - target_bits,
                'unit_area': sram['area'],
                'total_area': total_area,
                'tcyc': sram['tcyc'],
                'efficiency': target_bits / total_capacity * 100
            })
    
    # Debug: Print count by memory type
    type_counts = {}
    for opt in memory_options:
        mem_type = opt['type'].lower()
        if mem_type in ['sp', 'spram']:
            mem_type = 'SP/SPRAM'
        elif mem_type in ['dpram', 'dp']:
            mem_type = 'DPRAM/DP'
        else:
            mem_type = opt['type'].upper()
        type_counts[mem_type] = type_counts.get(mem_type, 0) + 1
    
    print(f"Found memory options by type: {type_counts}")
    
    # Also print all SP/SPRAM configurations found
    sp_options = [opt for opt in memory_options if opt['type'].lower() in ['sp', 'spram']]
    print(f"\nSP/SPRAM configurations found ({len(sp_options)}):")
    for sp in sp_options:
        print(f"  {sp['type']} {sp['len']}x{sp['wid']} = {sp['unit_size']} bits, tCYC={sp['tcyc']:.3f}ns")
    
    # Sort by tCYC first, then by total area
    sorted_options = sorted(memory_options, key=lambda x: (x['tcyc'], x['total_area']))
    
    print(f"Memory design options for {target_bits} bits:")
    print("=" * 100)
    print(f"{'Rank':<4} {'Type':<6} {'Config':<8} {'Units':<5} {'Total Cap':<9} {'Waste':<6} {'Efficiency':<10} {'tCYC(ns)':<8} {'Total Area':<10}")
    print("-" * 100)
    
    for i, option in enumerate(sorted_options[:15], 1):  # Show top 15
        config = f"{option['len']}x{option['wid']}"
        print(f"{i:<4} {option['type']:<6} {config:<8} {option['units_needed']:<5} "
              f"{option['total_capacity']:<9} {option['waste_bits']:<6} {option['efficiency']:<9.1f}% "
              f"{option['tcyc']:<8.3f} {option['total_area']:<10}")
    
    if sorted_options:
        best = sorted_options[0]
        print(f"\nRECOMMENDED: {best['units_needed']} units of {best['type']} {best['len']}x{best['wid']}")
        print(f"  - Each unit: {best['unit_size']} bits, Area: {best['unit_area']}")
        print(f"  - Total capacity: {best['total_capacity']} bits ({best['waste_bits']} wasted)")
        print(f"  - Total area: {best['total_area']}")
        print(f"  - tCYC: {best['tcyc']:.3f} ns")
        print(f"  - Max Frequency: {1000/best['tcyc']:.1f} MHz")
        print(f"  - Efficiency: {best['efficiency']:.1f}%")
    
    # Create graph of Total Area vs TOTAL
    totals = [opt['unit_size'] for opt in sorted_options]
    total_areas = [opt['total_area'] for opt in sorted_options]
    types = [opt['type'] for opt in sorted_options]
    
    # Color code by memory type
    colors = ['red' if t.lower() in ['dpram', 'dp'] else 'blue' if t.lower() in ['spram', 'sp'] else 'green' for t in types]
    
    plt.figure(figsize=(12, 8))
    plt.scatter(totals, total_areas, alpha=0.7, c=colors, s=60)
    
    # Add labels for different memory types
    dpram_totals = [opt['unit_size'] for opt in sorted_options if opt['type'].lower() in ['dpram', 'dp']]
    dpram_areas = [opt['total_area'] for opt in sorted_options if opt['type'].lower() in ['dpram', 'dp']]
    spram_totals = [opt['unit_size'] for opt in sorted_options if opt['type'].lower() in ['spram', 'sp']]
    spram_areas = [opt['total_area'] for opt in sorted_options if opt['type'].lower() in ['spram', 'sp']]
    rom_totals = [opt['unit_size'] for opt in sorted_options if opt['type'].lower() == 'rom']
    rom_areas = [opt['total_area'] for opt in sorted_options if opt['type'].lower() == 'rom']
    
    if dpram_totals:
        plt.scatter(dpram_totals, dpram_areas, alpha=0.7, color='red', label='DPRAM/DP', s=60)
    if spram_totals:
        plt.scatter(spram_totals, spram_areas, alpha=0.7, color='blue', label='SPRAM/SP', s=60)
    if rom_totals:
        plt.scatter(rom_totals, rom_areas, alpha=0.7, color='green', label='ROM', s=60)
    
    plt.xlabel('Unit Size (bits)')
    plt.ylabel('Total Area (for 32,080 bits)')
    plt.title(f'Memory Options for {target_bits} bits: Total Area vs Unit Size')
    plt.legend()
    plt.grid(True, alpha=0.3)
    plt.savefig("sram_memory_options.png")
    plt.show()
    
    return sorted_options

if __name__ == "__main__":
    results = find_best_4096_options()
